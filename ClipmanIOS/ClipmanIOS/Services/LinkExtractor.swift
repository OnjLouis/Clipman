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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeSingleURLCandidate(trimmed), !LinkPresentationSafety.isWithinURLLimit(trimmed) {
            return []
        }
        guard let detector else { return [] }
        let detectorText = removingOverlongURLCandidates(from: text)
        let range = NSRange(detectorText.startIndex..<detectorText.endIndex, in: detectorText)
        return detector
            .matches(in: detectorText, options: [], range: range)
            .compactMap(\.url)
            .filter { LinkPresentationSafety.isWithinURLLimit($0.absoluteString) }
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

    static func isExactWebsiteTitleTarget(_ entry: ClipEntry, matching selectedURL: URL) -> Bool {
        guard let onlyURL = exactHTTPURL(in: entry) else { return false }
        return onlyURL.absoluteString == selectedURL.absoluteString
    }

    static func exactHTTPURL(in entry: ClipEntry) -> URL? {
        guard let url = pureHTTPURL(in: entry.Text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    static func isLinkEntry(_ entry: ClipEntry) -> Bool {
        links(in: entry.Text).isEmpty == false
    }

    private static func pureHTTPURL(in text: String) -> URL? {
        // A pure link cannot legitimately exceed the URL limit by more than
        // modest surrounding whitespace. Reject oversized clipboard text
        // before trimming it, which would otherwise copy the entire string.
        guard text.unicodeScalars
            .prefix(LinkPresentationSafety.maximumURLScalars + 65)
            .count <= LinkPresentationSafety.maximumURLScalars + 64 else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n"), !trimmed.contains("\r") else { return nil }
        let candidate: String
        if let range = trimmed.range(
            of: #"\s+link$"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            candidate = String(trimmed[..<range.lowerBound])
        } else {
            candidate = trimmed
        }
        guard !candidate.contains(where: \.isWhitespace),
              LinkPresentationSafety.isWithinURLLimit(candidate),
              let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "clipman",
              components.host?.isEmpty == false else {
            return nil
        }
        return components.url
    }

    private static func looksLikeSingleURLCandidate(_ value: String) -> Bool {
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { return false }
        let lower = value.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("clipman://")
    }

    private static func removingOverlongURLCandidates(from text: String) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isWhitespace).map { part in
            let value = String(part)
            let lower = value.lowercased()
            let looksLikeURL = lower.contains("http://") || lower.contains("https://") || lower.contains("clipman://")
            return looksLikeURL && !LinkPresentationSafety.isWithinURLLimit(value) ? "" : value
        }.joined(separator: " ")
    }
}
