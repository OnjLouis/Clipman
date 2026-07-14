import Foundation

enum HistoryTabID {
    static let text = "Text"
    static let links = "Links"
    static let files = "Files"

    static func normalize(_ value: String?, linksEnabled: Bool) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare(files) == .orderedSame {
            return files
        }
        if linksEnabled, trimmed.caseInsensitiveCompare(links) == .orderedSame {
            return links
        }
        return text
    }
}
