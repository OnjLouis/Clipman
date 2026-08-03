import Foundation

struct MobileSyncResult: Sendable {
    var database: ClipDatabase
    var revision: String
    var uploaded: Bool
    var backupError: String?
}

struct MobileMutationError: Error, LocalizedError, Sendable {
    var localSaved: Bool
    var message: String

    var errorDescription: String? { message }
}

private struct MobileSyncState: Codable {
    var identity: String
    var revision: String
}

protocol MobileHistoryRepositoryProtocol: Sendable {
    func loadLocal(password: String) async throws -> ClipDatabase?
    func saveLocal(
        _ database: ClipDatabase,
        password: String,
        backupSettings: ClipmanSettings?
    ) async throws -> String?
    func synchronize(
        settings: ClipmanSettings,
        current: ClipDatabase,
        localAlreadySaved: Bool
    ) async throws -> MobileSyncResult
    func persistMutation(
        settings: ClipmanSettings,
        current: ClipDatabase,
        expectedRevision: String
    ) async throws -> MobileSyncResult
}

actor MobileHistoryRepository: MobileHistoryRepositoryProtocol {
    static let shared = MobileHistoryRepository()

    private let fileManager = FileManager.default
    private var localEncryptedSalt: [UInt8]?

    func loadLocal(password: String) async throws -> ClipDatabase? {
        let url = try localDatabaseURL(createDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try ClipDatabaseFile.readBounded(from: url)
        localEncryptedSalt = ClipDatabaseFile.encryptedSalt(from: data)
        return try await DatabaseWorker.load(data: data, password: password)
    }

    @discardableResult
    func saveLocal(
        _ database: ClipDatabase,
        password: String,
        backupSettings: ClipmanSettings? = nil
    ) async throws -> String? {
        let data = try await DatabaseWorker.save(
            database,
            password: password,
            preferredSalt: localEncryptedSalt
        )
        return try persistEncodedLocal(data, password: password, backupSettings: backupSettings)
    }

    func persistMutation(
        settings: ClipmanSettings,
        current: ClipDatabase,
        expectedRevision: String
    ) async throws -> MobileSyncResult {
        let client = ServerStorageClient(settings: settings)
        let previousState = loadSyncState()
        let data: Data
        let backupError: String?
        do {
            data = try await DatabaseWorker.save(
                current,
                password: settings.historyPassword,
                preferredSalt: localEncryptedSalt
            )
            backupError = try persistEncodedLocal(
                data,
                password: settings.historyPassword,
                backupSettings: settings
            )
        } catch {
            throw MobileMutationError(localSaved: false, message: error.localizedDescription)
        }

        let knownRevision: String = {
            if !expectedRevision.isEmpty { return expectedRevision }
            if previousState?.identity == client.syncCacheIdentity {
                return previousState?.revision ?? ""
            }
            return ""
        }()

        if !knownRevision.isEmpty {
            do {
                let newRevision = try await client.upload(data: data, expectedRevision: knownRevision)
                saveSyncState(identity: client.syncCacheIdentity, revision: newRevision)
                return MobileSyncResult(
                    database: current,
                    revision: newRevision,
                    uploaded: true,
                    backupError: backupError
                )
            } catch ServerStorageError.conflict {
                // Another client changed the database. Fall through to a full merge.
            } catch ServerStorageError.notFound {
                // The server bucket was removed. Fall through to the normal create path.
            } catch {
                throw MobileMutationError(localSaved: true, message: error.localizedDescription)
            }
        }

        do {
            var result = try await synchronize(
                settings: settings,
                current: current,
                localAlreadySaved: true
            )
            result.backupError = result.backupError ?? backupError
            return result
        } catch {
            throw MobileMutationError(localSaved: true, message: error.localizedDescription)
        }
    }

    private func persistEncodedLocal(
        _ data: Data,
        password: String,
        backupSettings: ClipmanSettings?
    ) throws -> String? {
        let url = try localDatabaseURL(createDirectory: true)
        clearSyncState()
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        localEncryptedSalt = ClipDatabaseFile.encryptedSalt(from: data)
        guard let backupSettings, backupSettings.cloudBackupEnabled else { return nil }
        guard !password.isEmpty else {
            return "Set a nonblank history password before enabling cloud backup."
        }
        do {
            try CloudHistoryBackup.write(data, bookmark: backupSettings.cloudBackupBookmark)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func synchronize(
        settings: ClipmanSettings,
        current: ClipDatabase,
        localAlreadySaved: Bool = false
    ) async throws -> MobileSyncResult {
        let cached: ClipDatabase?
        if localAlreadySaved {
            cached = current
        } else {
            cached = try await loadLocal(password: settings.historyPassword)
        }
        let local = if localAlreadySaved {
            current
        } else if let cached {
            SyncConflictResolver.merge(target: current, source: cached)
        } else {
            current
        }
        let client = ServerStorageClient(settings: settings)
        if localAlreadySaved,
           let state = loadSyncState(),
           state.identity == client.syncCacheIdentity,
           !state.revision.isEmpty {
            do {
                let metadata = try await client.metadata()
                if metadata.revision == state.revision {
                    return MobileSyncResult(database: local, revision: state.revision, uploaded: false, backupError: nil)
                }
            } catch ServerStorageError.notFound {
                // Continue through the normal create path below.
            } catch {
                throw error
            }
        }
        let download: ServerDatabaseDownload
        do {
            download = try await client.download()
        } catch ServerStorageError.notFound {
            let data = try await DatabaseWorker.save(
                local,
                password: settings.historyPassword,
                preferredSalt: localEncryptedSalt
            )
            let revision = try await client.upload(data: data, expectedRevision: "")
            if cached.map({ !SyncConflictResolver.hasSameContent(local, $0) }) ?? true {
                let backupError = try await saveLocal(
                    local,
                    password: settings.historyPassword,
                    backupSettings: settings
                )
                saveSyncState(identity: client.syncCacheIdentity, revision: revision)
                return MobileSyncResult(database: local, revision: revision, uploaded: true, backupError: backupError)
            }
            saveSyncState(identity: client.syncCacheIdentity, revision: revision)
            return MobileSyncResult(database: local, revision: revision, uploaded: true, backupError: nil)
        }

        let remote = try await DatabaseWorker.load(data: download.data, password: settings.historyPassword)
        let merged = SyncConflictResolver.merge(target: local, source: remote)
        let mergedMatchesRemote = SyncConflictResolver.hasSameContent(merged, remote)
        guard !mergedMatchesRemote else {
            if cached.map({ !SyncConflictResolver.hasSameContent(merged, $0) }) ?? true {
                let backupError = try await saveLocal(
                    merged,
                    password: settings.historyPassword,
                    backupSettings: settings
                )
                saveSyncState(identity: client.syncCacheIdentity, revision: download.revision)
                return MobileSyncResult(database: merged, revision: download.revision, uploaded: false, backupError: backupError)
            }
            saveSyncState(identity: client.syncCacheIdentity, revision: download.revision)
            return MobileSyncResult(database: merged, revision: download.revision, uploaded: false, backupError: nil)
        }
        let data = try await DatabaseWorker.save(
            merged,
            password: settings.historyPassword,
            preferredSalt: localEncryptedSalt
        )
        let revision = try await client.upload(data: data, expectedRevision: download.revision)
        if cached.map({ !SyncConflictResolver.hasSameContent(merged, $0) }) ?? true {
            let backupError = try await saveLocal(
                merged,
                password: settings.historyPassword,
                backupSettings: settings
            )
            saveSyncState(identity: client.syncCacheIdentity, revision: revision)
            return MobileSyncResult(database: merged, revision: revision, uploaded: true, backupError: backupError)
        }
        saveSyncState(identity: client.syncCacheIdentity, revision: revision)
        return MobileSyncResult(database: merged, revision: revision, uploaded: true, backupError: nil)
    }

    private func localDatabaseURL(createDirectory: Bool) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: createDirectory
        )
        let directory = base.appendingPathComponent("Clipman", isDirectory: true)
        if createDirectory {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("clipman-history.clipdb", isDirectory: false)
    }

    private func syncStateURL(createDirectory: Bool) throws -> URL {
        try localDatabaseURL(createDirectory: createDirectory)
            .deletingLastPathComponent()
            .appendingPathComponent("server-sync-state.json", isDirectory: false)
    }

    private func loadSyncState() -> MobileSyncState? {
        guard let url = try? syncStateURL(createDirectory: false),
              let data = try? Data(contentsOf: url),
              data.count <= 16_384 else { return nil }
        return try? JSONDecoder().decode(MobileSyncState.self, from: data)
    }

    private func saveSyncState(identity: String, revision: String) {
        guard !identity.isEmpty, !revision.isEmpty,
              let data = try? JSONEncoder().encode(MobileSyncState(identity: identity, revision: revision)),
              let url = try? syncStateURL(createDirectory: true) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private func clearSyncState() {
        guard let url = try? syncStateURL(createDirectory: false) else { return }
        try? fileManager.removeItem(at: url)
    }
}
