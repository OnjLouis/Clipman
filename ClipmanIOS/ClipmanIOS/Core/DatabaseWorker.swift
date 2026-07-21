import Foundation

enum DatabaseWorker {
    static func load(data: Data, password: String) async throws -> ClipDatabase {
        try await Task.detached(priority: .userInitiated) {
            try ClipDatabaseFile.load(data, password: password)
        }.value
    }

    static func save(_ database: ClipDatabase, password: String) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try ClipDatabaseFile.save(database, password: password)
        }.value
    }
}
