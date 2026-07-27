import Foundation

enum HistoryTabID {
    static let text = "Text"
    static let links = "Links"
    static let richText = "RichText"
    static let files = "Files"
    static let defaultOrder = [text, links, richText, files]

    static func normalizeOrder(_ values: [String]?) -> [String] {
        var result: [String] = []
        for value in values ?? [] {
            guard let canonical = canonical(value), !result.contains(where: { $0.caseInsensitiveCompare(canonical) == .orderedSame }) else { continue }
            result.append(canonical)
        }
        for value in defaultOrder where !result.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
            result.append(value)
        }
        return result
    }

    static func visibleOrder(_ values: [String]?, linksEnabled: Bool, richTextEnabled: Bool) -> [String] {
        normalizeOrder(values).filter { value in
            (value != links || linksEnabled) && (value != richText || richTextEnabled)
        }
    }

    static func moving(_ values: [String]?, selected: String, direction: Int, linksEnabled: Bool, richTextEnabled: Bool) -> [String]? {
        var result = normalizeOrder(values)
        let visible = visibleOrder(result, linksEnabled: linksEnabled, richTextEnabled: richTextEnabled)
        guard direction != 0,
              let selectedIndex = visible.firstIndex(where: { $0.caseInsensitiveCompare(selected) == .orderedSame })
        else { return nil }
        let targetIndex = selectedIndex + (direction < 0 ? -1 : 1)
        guard visible.indices.contains(targetIndex),
              let first = result.firstIndex(of: visible[selectedIndex]),
              let second = result.firstIndex(of: visible[targetIndex])
        else { return nil }
        result.swapAt(first, second)
        return result
    }

    static func normalize(_ value: String?, linksEnabled: Bool, richTextEnabled: Bool = false) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare(files) == .orderedSame {
            return files
        }
        if linksEnabled, trimmed.caseInsensitiveCompare(links) == .orderedSame {
            return links
        }
        if richTextEnabled, trimmed.caseInsensitiveCompare(richText) == .orderedSame {
            return richText
        }
        return text
    }

    private static func canonical(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return defaultOrder.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }
}
