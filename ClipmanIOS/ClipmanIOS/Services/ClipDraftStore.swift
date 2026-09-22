import Foundation

struct ClipDraftStore {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() throws -> ClipEntry? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(ClipEntry.self, from: Data(contentsOf: fileURL))
    }

    func save(_ draft: ClipEntry) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: fileURL, options: .atomic)
#if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: fileURL.path
        )
#endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = fileURL
        try mutableURL.setResourceValues(values)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    static var quickClipFileURL: URL {
        draftFileURL(named: "quick-clip-draft.json")
    }

    static var entryEditFileURL: URL {
        draftFileURL(named: "entry-edit-draft.json")
    }

    private static func draftFileURL(named filename: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Clipman", isDirectory: true)
            .appendingPathComponent(filename)
    }
}
