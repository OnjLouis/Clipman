import Foundation

enum LinkClipboardText {
    static func make(entry: ClipEntry, url: URL, includeName: Bool) -> String {
        let link = url.absoluteString
        let name = entry.Name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard includeName, !name.isEmpty else { return link }
        return "\(name)\n\(link)"
    }
}
