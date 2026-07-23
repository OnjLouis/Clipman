import Foundation

enum LinkExtractor {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    struct LinkItem: Identifiable, Equatable {
        let id: String
        let url: URL
        let entry: ClipEntry
    }

    static func links(in text: String) -> [URL] {
        if let url = pureHTTPURL(in: text) {
            return [url]
        }
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
        pureHTTPURL(in: entry.Text) != nil
    }

    static func isLinkEntry(_ entry: ClipEntry) -> Bool {
        links(in: entry.Text).isEmpty == false
    }

    private static func pureHTTPURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("\n"),
              !trimmed.contains("\r"),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "clipman",
              components.host?.isEmpty == false else {
            return nil
        }
        return components.url
    }
}
