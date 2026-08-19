import Foundation

struct PendingSharedText: Sendable, Equatable {
    let id: String
    let fileURL: URL
    let text: String
    let html: String
}

enum PendingSharedTextError: LocalizedError, Equatable {
    case appGroupUnavailable
    case emptyText
    case textTooLarge
    case queueFull
    case invalidQueueItem

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "Clipman's shared text storage is unavailable."
        case .emptyText:
            return "The shared item does not contain readable text or a link."
        case .textTooLarge:
            return "The shared text exceeds Clipman's 1 MiB input limit."
        case .queueFull:
            return "Clipman already has 16 text items waiting to be added. Open Clipman before sharing another."
        case .invalidQueueItem:
            return "A pending shared text item is incomplete."
        }
    }
}

struct PendingSharedTextStore: Sendable {
    static let appGroupIdentifier = PendingSharedImageStore.appGroupIdentifier
    static let maximumTextBytes = 1024 * 1024
    static let maximumHTMLBytes = 768 * 1024
    static let maximumPendingItems = 16

    private struct Payload: Codable {
        let text: String
        let html: String
    }

    private let rootURL: URL

    init(rootURL: URL? = nil) throws {
        if let rootURL {
            self.rootURL = rootURL
        } else if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) {
            self.rootURL = container.appendingPathComponent("PendingSharedText", isDirectory: true)
        } else {
            throw PendingSharedTextError.appGroupUnavailable
        }
    }

    func enqueue(text: String, html: String = "") throws -> PendingSharedText {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { throw PendingSharedTextError.emptyText }
        guard cleanText.utf8.count <= Self.maximumTextBytes,
              html.utf8.count <= Self.maximumHTMLBytes else {
            throw PendingSharedTextError.textTooLarge
        }
        try prepareRoot()
        guard try pendingItems().count < Self.maximumPendingItems else {
            throw PendingSharedTextError.queueFull
        }

        let id = UUID().uuidString.lowercased()
        let destination = rootURL.appendingPathComponent("share-\(id).json", isDirectory: false)
        let data = try JSONEncoder().encode(Payload(text: cleanText, html: html))
        try data.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
        return try item(at: destination)
    }

    func pendingItems() throws -> [PendingSharedText] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.lastPathComponent.hasPrefix("share-") && $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .compactMap { try? item(at: $0) }
    }

    func remove(_ item: PendingSharedText) throws {
        let root = rootURL.standardizedFileURL.path + "/"
        let itemPath = item.fileURL.standardizedFileURL.path
        guard itemPath.hasPrefix(root),
              item.fileURL.lastPathComponent.hasPrefix("share-"),
              item.fileURL.pathExtension == "json" else {
            throw PendingSharedTextError.invalidQueueItem
        }
        try FileManager.default.removeItem(at: item.fileURL)
    }

    private func prepareRoot() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    private func item(at fileURL: URL) throws -> PendingSharedText {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size > 0,
              size <= Self.maximumTextBytes + Self.maximumHTMLBytes + 4096 else {
            throw PendingSharedTextError.invalidQueueItem
        }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: fileURL))
        let cleanText = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty,
              cleanText.utf8.count <= Self.maximumTextBytes,
              payload.html.utf8.count <= Self.maximumHTMLBytes else {
            throw PendingSharedTextError.invalidQueueItem
        }
        return PendingSharedText(
            id: fileURL.deletingPathExtension().lastPathComponent,
            fileURL: fileURL,
            text: cleanText,
            html: payload.html
        )
    }
}
