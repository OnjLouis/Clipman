import Foundation

struct MobileSyncResult: Sendable {
    var database: ClipDatabase
    var revision: String
    var uploaded: Bool
}

actor MobileHistoryRepository {
    private let fileManager = FileManager.default

    func loadLocal(password: String) async throws -> ClipDatabase? {
        let url = try localDatabaseURL(createDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try await DatabaseWorker.load(data: data, password: password)
    }

    func saveLocal(_ database: ClipDatabase, password: String) async throws {
        let data = try await DatabaseWorker.save(database, password: password)
        let url = try localDatabaseURL(createDirectory: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    func synchronize(settings: ClipmanSettings, current: ClipDatabase) async throws -> MobileSyncResult {
        let cached = try await loadLocal(password: settings.historyPassword)
        let local = if let cached {
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
                try await saveLocal(local, password: settings.historyPassword)
            }
            return MobileSyncResult(database: local, revision: revision, uploaded: true)
        }

        for attempt in 0..<3 {
            let remote = try await DatabaseWorker.load(data: download.data, password: settings.historyPassword)
            let merged = SyncConflictResolver.merge(target: local, source: remote)
            guard !SyncConflictResolver.hasSameContent(merged, remote) else {
                if cached.map({ !SyncConflictResolver.hasSameContent(merged, $0) }) ?? true {
                    try await saveLocal(merged, password: settings.historyPassword)
                }
                return MobileSyncResult(database: merged, revision: download.revision, uploaded: false)
            }
            do {
                let data = try await DatabaseWorker.save(merged, password: settings.historyPassword)
                let revision = try await client.upload(data: data, expectedRevision: download.revision)
                if cached.map({ !SyncConflictResolver.hasSameContent(merged, $0) }) ?? true {
                    try await saveLocal(merged, password: settings.historyPassword)
                }
                return MobileSyncResult(database: merged, revision: revision, uploaded: true)
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
