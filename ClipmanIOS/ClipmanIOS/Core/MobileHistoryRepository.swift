import Foundation

struct MobileSyncResult: Sendable {
    var database: ClipDatabase
    var revision: String
    var uploaded: Bool
    var backupError: String?
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
}

actor MobileHistoryRepository: MobileHistoryRepositoryProtocol {
    static let shared = MobileHistoryRepository()

    private let fileManager = FileManager.default

    func loadLocal(password: String) async throws -> ClipDatabase? {
        let url = try localDatabaseURL(createDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try ClipDatabaseFile.readBounded(from: url)
        return try await DatabaseWorker.load(data: data, password: password)
    }

    @discardableResult
    func saveLocal(
        _ database: ClipDatabase,
        password: String,
        backupSettings: ClipmanSettings? = nil
    ) async throws -> String? {
        let data = try await DatabaseWorker.save(database, password: password)
        let url = try localDatabaseURL(createDirectory: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
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
        var download: ServerDatabaseDownload
        do {
            download = try await client.download()
        } catch ServerStorageError.notFound {
            let data = try await DatabaseWorker.save(local, password: settings.historyPassword)
            let revision = try await client.upload(data: data, expectedRevision: "")
            if cached.map({ !SyncConflictResolver.hasSameContent(local, $0) }) ?? true {
                let backupError = try await saveLocal(
                    local,
                    password: settings.historyPassword,
                    backupSettings: settings
                )
                return MobileSyncResult(database: local, revision: revision, uploaded: true, backupError: backupError)
            }
            return MobileSyncResult(database: local, revision: revision, uploaded: true, backupError: nil)
        }

        for attempt in 0..<3 {
            let remote = try await DatabaseWorker.load(data: download.data, password: settings.historyPassword)
            let merged = SyncConflictResolver.merge(target: local, source: remote)
            guard !SyncConflictResolver.hasSameContent(merged, remote) else {
                if cached.map({ !SyncConflictResolver.hasSameContent(merged, $0) }) ?? true {
                    let backupError = try await saveLocal(
                        merged,
                        password: settings.historyPassword,
                        backupSettings: settings
                    )
                    return MobileSyncResult(database: merged, revision: download.revision, uploaded: false, backupError: backupError)
                }
                return MobileSyncResult(database: merged, revision: download.revision, uploaded: false, backupError: nil)
            }
            do {
                let data = try await DatabaseWorker.save(merged, password: settings.historyPassword)
                let revision = try await client.upload(data: data, expectedRevision: download.revision)
                if cached.map({ !SyncConflictResolver.hasSameContent(merged, $0) }) ?? true {
                    let backupError = try await saveLocal(
                        merged,
                        password: settings.historyPassword,
                        backupSettings: settings
                    )
                    return MobileSyncResult(database: merged, revision: revision, uploaded: true, backupError: backupError)
                }
                return MobileSyncResult(database: merged, revision: revision, uploaded: true, backupError: nil)
            } catch ServerStorageError.conflict where attempt < 2 {
                download = try await client.download()
            }
        }
        throw ServerStorageError.conflict
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
}
