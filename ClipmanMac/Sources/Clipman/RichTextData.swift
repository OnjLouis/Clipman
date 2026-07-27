import AppKit
import ClipmanCore

enum RichTextData {
    static let maxHTMLBytes = 768 * 1024
    static let maxRTFBytes = 1024 * 1024
    static let maxCombinedBytes = 1792 * 1024

    static func capture(from pasteboard: NSPasteboard) -> RichTextPayload? {
        let html = pasteboard.data(forType: .html).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let rtf = pasteboard.data(forType: .rtf)
        return normalize(RichTextPayload(
            HtmlFragment: html,
            RtfBase64: rtf?.base64EncodedString() ?? "",
            PreferredFormat: !html.isEmpty ? "Html" : rtf != nil ? "Rtf" : ""
        ))
    }

    static func write(_ payload: RichTextPayload?, to pasteboard: NSPasteboard) {
        guard let payload = normalize(payload) else { return }
        if let html = payload.HtmlFragment.data(using: .utf8), !html.isEmpty {
            pasteboard.setData(html, forType: .html)
        }
        if let rtf = Data(base64Encoded: payload.RtfBase64), !rtf.isEmpty {
            pasteboard.setData(rtf, forType: .rtf)
        }
    }

    static func normalize(_ payload: RichTextPayload?) -> RichTextPayload? {
        guard let payload else { return nil }
        var html = payload.HtmlFragment
        if html.utf8.count > maxHTMLBytes { html = "" }
        var rtf = Data(base64Encoded: payload.RtfBase64)
        if let value = rtf, value.count > maxRTFBytes { rtf = nil }
        if html.utf8.count + (rtf?.count ?? 0) > maxCombinedBytes {
            if !html.isEmpty { rtf = nil } else { return nil }
        }
        guard !html.isEmpty || !(rtf?.isEmpty ?? true) else { return nil }
        let requestedRTF = payload.PreferredFormat.caseInsensitiveCompare("Rtf") == .orderedSame
        let preferred = requestedRTF && !(rtf?.isEmpty ?? true) ? "Rtf" : !html.isEmpty ? "Html" : "Rtf"
        return RichTextPayload(
            Version: 1,
            HtmlFragment: html,
            RtfBase64: rtf?.base64EncodedString() ?? "",
            PreferredFormat: preferred
        )
    }
}
