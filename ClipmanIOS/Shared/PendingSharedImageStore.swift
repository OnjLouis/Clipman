import Foundation

struct PendingSharedImage: Sendable, Equatable {
    let id: String
    let directoryURL: URL
    let imageURL: URL
    let suggestedFilename: String
}

enum PendingSharedImageError: LocalizedError, Equatable {
    case appGroupUnavailable
    case emptyImage
    case imageTooLarge
    case queueFull
    case invalidQueueItem

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "Clipman's shared photo storage is unavailable."
        case .emptyImage:
            return "The selected photo is empty."
        case .imageTooLarge:
            return "The selected photo exceeds Clipman's 16 MiB input limit."
        case .queueFull:
            return "Clipman already has four photos waiting to be added. Open Clipman before sharing another."
        case .invalidQueueItem:
            return "A pending shared photo is incomplete."
        }
    }
}

struct PendingSharedImageStore: Sendable {
    static let appGroupIdentifier = "group.me.onj.clipman.ios"
    static let maximumInputBytes = 16 * 1024 * 1024
    static let maximumPendingItems = 4

    private struct Metadata: Codable {
        let filename: String
    }

    private let rootURL: URL

    init(rootURL: URL? = nil) throws {
        if let rootURL {
            self.rootURL = rootURL
        } else if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) {
            self.rootURL = container.appendingPathComponent("PendingSharedImages", isDirectory: true)
        } else {
            throw PendingSharedImageError.appGroupUnavailable
        }
    }

    func enqueue(sourceURL: URL, suggestedFilename: String?) throws -> PendingSharedImage {
        try prepareRoot()
        guard try pendingItems().count < Self.maximumPendingItems else {
            throw PendingSharedImageError.queueFull
        }

        let id = UUID().uuidString.lowercased()
        let temporary = rootURL.appendingPathComponent(".tmp-\(id)", isDirectory: true)
        let destination = rootURL.appendingPathComponent("share-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        do {
            try copyBounded(
                from: sourceURL,
                to: temporary.appendingPathComponent("image", isDirectory: false)
            )
            let metadata = try JSONEncoder().encode(Metadata(filename: Self.safeFilename(suggestedFilename)))
            try metadata.write(
                to: temporary.appendingPathComponent("metadata.json", isDirectory: false),
                options: [.atomic, .completeFileProtectionUnlessOpen]
            )
            try FileManager.default.moveItem(at: temporary, to: destination)
            return try item(at: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    func pendingItems() throws -> [PendingSharedImage] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.lastPathComponent.hasPrefix("share-") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .compactMap { try? item(at: $0) }
    }

    func readBounded(_ item: PendingSharedImage) throws -> Data {
        let values = try item.imageURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw PendingSharedImageError.invalidQueueItem }
        let size = values.fileSize ?? 0
        guard size > 0 else { throw PendingSharedImageError.emptyImage }
        guard size <= Self.maximumInputBytes else { throw PendingSharedImageError.imageTooLarge }
        let data = try Data(contentsOf: item.imageURL, options: [.mappedIfSafe])
        guard !data.isEmpty else { throw PendingSharedImageError.emptyImage }
        guard data.count <= Self.maximumInputBytes else { throw PendingSharedImageError.imageTooLarge }
        return data
    }

    func remove(_ item: PendingSharedImage) throws {
        let root = rootURL.standardizedFileURL.path + "/"
        let itemPath = item.directoryURL.standardizedFileURL.path
        guard itemPath.hasPrefix(root), item.directoryURL.lastPathComponent.hasPrefix("share-") else {
            throw PendingSharedImageError.invalidQueueItem
        }
        try FileManager.default.removeItem(at: item.directoryURL)
    }

    private func prepareRoot() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        for url in try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) where url.lastPathComponent.hasPrefix(".tmp-") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func item(at directory: URL) throws -> PendingSharedImage {
        let imageURL = directory.appendingPathComponent("image", isDirectory: false)
        let metadataURL = directory.appendingPathComponent("metadata.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: imageURL.path),
              FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw PendingSharedImageError.invalidQueueItem
        }
        let metadataData = try Data(contentsOf: metadataURL)
        guard metadataData.count <= 4096 else { throw PendingSharedImageError.invalidQueueItem }
        let metadata = try JSONDecoder().decode(Metadata.self, from: metadataData)
        return PendingSharedImage(
            id: directory.lastPathComponent,
            directoryURL: directory,
            imageURL: imageURL,
            suggestedFilename: Self.safeFilename(metadata.filename)
        )
    }

    private func copyBounded(from source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }
        var total = 0
        while true {
            let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            total += chunk.count
            guard total <= Self.maximumInputBytes else { throw PendingSharedImageError.imageTooLarge }
            try output.write(contentsOf: chunk)
        }
        guard total > 0 else { throw PendingSharedImageError.emptyImage }
        try output.synchronize()
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: destination.path
        )
    }

    private static func safeFilename(_ value: String?) -> String {
        let component = (value ?? "")
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? ""
        let filtered = String(component.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0.value != 0xfffd
        })
        let clipped = String(filtered.prefix(240)).trimmingCharacters(in: .whitespacesAndNewlines)
        return clipped.isEmpty ? "Shared photo" : clipped
    }
}
