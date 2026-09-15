import Foundation

final class EmbeddedImagePasteboardFile {
    let fileURL: URL
    private let directoryURL: URL

    init(data: Data, filename: String, capturedUnixMs: Int64? = nil) throws {
        let root = Self.rootDirectory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directoryURL = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        fileURL = directoryURL.appendingPathComponent(filename, isDirectory: false)
        do {
            try data.write(to: fileURL, options: .atomic)
            if let capturedDate = Self.validCapturedDate(capturedUnixMs) {
                try? FileManager.default.setAttributes(
                    [.creationDate: capturedDate, .modificationDate: capturedDate],
                    ofItemAtPath: fileURL.path
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    static func removeStaleFiles() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    private static var rootDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Clipman Clipboard Files", isDirectory: true)
    }

    private static func validCapturedDate(_ capturedUnixMs: Int64?, now: Date = Date()) -> Date? {
        guard let capturedUnixMs, capturedUnixMs > 0 else { return nil }
        let interval = TimeInterval(capturedUnixMs) / 1_000
        guard interval.isFinite else { return nil }
        let capturedDate = Date(timeIntervalSince1970: interval)
        guard capturedDate <= now.addingTimeInterval(24 * 60 * 60) else { return nil }
        return capturedDate
    }
}
