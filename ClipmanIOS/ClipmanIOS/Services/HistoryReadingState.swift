import Foundation

struct HistoryReadingState: Codable, Equatable {
    var section = "Text"
    var historyAnchors: [String: String] = [:]
    var historyFocusID: String?
    var viewedEntryID: String?
    var viewerAnchor: String?
    var viewerFocusID: String?
    var showingLargeImage = false
}

struct HistoryReadingStateStore {
    let fileURL: URL

    func load() throws -> HistoryReadingState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(HistoryReadingState.self, from: Data(contentsOf: fileURL))
    }

    func save(_ state: HistoryReadingState) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // References only: clipboard text, names, URLs and image data stay in the history database.
        try JSONEncoder().encode(state).write(to: fileURL, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = fileURL
        try url.setResourceValues(values)
    }

    static var fileURL: URL {
        ClipDraftStore.quickClipFileURL.deletingLastPathComponent().appendingPathComponent("history-reading-state.json")
    }
}
