import Foundation

enum DatabaseWorker {
    static func loadAndMerge(data: Data, password: String, current: ClipDatabase) async throws -> ClipDatabase {
        try await Task.detached(priority: .userInitiated) {
            let remote = try ClipDatabaseFile.load(data, password: password)
            return SyncConflictResolver.merge(target: current, source: remote)
        }.value
    }

    static func save(_ database: ClipDatabase, password: String) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try ClipDatabaseFile.save(database, password: password)
        }.value
    }
}
