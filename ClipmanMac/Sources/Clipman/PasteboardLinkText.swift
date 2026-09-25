import AppKit

enum PasteboardLinkText {
    private static let urlType = NSPasteboard.PasteboardType("public.url")
    private static let maximumURLCharacters = 8192

    static func read(from pasteboard: NSPasteboard) -> String? {
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return text
        }
        let raw = pasteboard.string(forType: urlType)
            ?? pasteboard.data(forType: urlType).flatMap { String(data: $0, encoding: .utf8) }
        guard let candidate = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty,
              candidate.count <= maximumURLCharacters,
              let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "clipman"].contains(scheme),
              url.host?.isEmpty == false else {
            return nil
        }
        return candidate
    }
}
