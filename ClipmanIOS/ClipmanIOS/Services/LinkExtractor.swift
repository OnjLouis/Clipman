import Foundation

enum LinkExtractor {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    struct LinkItem: Identifiable, Equatable {
        let id: String
        let url: URL
        let entry: ClipEntry
    }

    static func links(in text: String) -> [URL] {
        guard let detector else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector
            .matches(in: text, options: [], range: range)
            .compactMap(\.url)
    }

    static func linkItems(in entries: [ClipEntry]) -> [LinkItem] {
        entries.flatMap { entry in
            links(in: entry.Text).enumerated().map { index, url in
                LinkItem(id: "\(entry.Id)-link-\(index)", url: url, entry: entry)
            }
        }
    }

    static func isPureLinkEntry(_ entry: ClipEntry) -> Bool {
        let trimmed = entry.Text.trimmingCharacters(in: .whitespacesAndNewlines)
        let links = links(in: trimmed)
        guard links.count == 1, let link = links.first else { return false }
        return trimmed == link.absoluteString
    }

    static func isLinkEntry(_ entry: ClipEntry) -> Bool {
        links(in: entry.Text).isEmpty == false
    }
}
