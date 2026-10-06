import Foundation

enum ServerAppReplacement {
    static func replace(source: URL, destination: URL,
                        move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws {
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let identifier = UUID().uuidString
        let staged = parent.appendingPathComponent(".clipman-server-update-\(identifier).app")
        let backup = parent.appendingPathComponent(".clipman-server-rollback-\(identifier).app")
        defer { try? manager.removeItem(at: staged) }
        try manager.copyItem(at: source, to: staged)
        try move(destination, backup)
        do {
            try move(staged, destination)
        } catch {
            // Keep the backup if restoration itself fails, rather than losing it.
            try manager.moveItem(at: backup, to: destination)
            throw error
        }
        try? manager.removeItem(at: backup)
    }
}
