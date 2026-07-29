import Foundation

enum CloudHistoryBackupError: LocalizedError {
    case folderUnavailable
    case staleBookmark
    case unencryptedBackup
    case backupTooLarge

    var errorDescription: String? {
        switch self {
        case .folderUnavailable:
            return "The selected backup folder is no longer available. Choose it again in Settings."
        case .staleBookmark:
            return "The saved backup folder permission has expired. Choose the folder again in Settings."
        case .unencryptedBackup:
            return "Cloud history backups must be encrypted with a nonblank history password."
        case .backupTooLarge:
            return "This history backup is too large."
        }
    }
}

enum CloudHistoryBackup {
    static let fileName = "Clipman History.clipdb"
    private static let maximumBackupBytes = 128 * 1024 * 1024
    private static let encryptedMagic = Data("CLIPDB2".utf8)

    static func bookmark(for directory: URL) throws -> Data {
        guard directory.startAccessingSecurityScopedResource() else {
            throw CloudHistoryBackupError.folderUnavailable
        }
        defer { directory.stopAccessingSecurityScopedResource() }
        return try directory.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func write(_ data: Data, bookmark: Data) throws {
        guard data.starts(with: encryptedMagic) else {
            throw CloudHistoryBackupError.unencryptedBackup
        }
        let directory = try resolve(bookmark)
        guard directory.startAccessingSecurityScopedResource() else {
            throw CloudHistoryBackupError.folderUnavailable
        }
        defer { directory.stopAccessingSecurityScopedResource() }

        let target = directory.appendingPathComponent(fileName, isDirectory: false)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: target, options: [], error: &coordinationError) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    static func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize <= maximumBackupBytes else { throw CloudHistoryBackupError.backupTooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard data.count <= maximumBackupBytes - chunk.count else {
                throw CloudHistoryBackupError.backupTooLarge
            }
            data.append(chunk)
        }
        guard data.starts(with: encryptedMagic) else {
            throw CloudHistoryBackupError.unencryptedBackup
        }
        return data
    }

    private static func resolve(_ bookmark: Data) throws -> URL {
        guard !bookmark.isEmpty else { throw CloudHistoryBackupError.folderUnavailable }
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale else { throw CloudHistoryBackupError.staleBookmark }
        return url
    }
}
