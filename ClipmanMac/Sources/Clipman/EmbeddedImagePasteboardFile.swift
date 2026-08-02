import Foundation

final class EmbeddedImagePasteboardFile {
    let fileURL: URL
    private let directoryURL: URL

    init(data: Data, filename: String) throws {
        let root = Self.rootDirectory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directoryURL = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        fileURL = directoryURL.appendingPathComponent(filename, isDirectory: false)
        do {
            try data.write(to: fileURL, options: .atomic)
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
}
