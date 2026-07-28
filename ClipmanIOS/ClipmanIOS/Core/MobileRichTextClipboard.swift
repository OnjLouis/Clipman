import CoreTransferable
import Foundation
import UIKit
import UniformTypeIdentifiers

struct MobileClipboardPayload: Transferable, Sendable {
    let text: String
    let richText: RichTextPayload?

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .html) { data in
            MobileClipboardPayload(
                text: plainText(from: data, documentType: .html),
                richText: MobileRichTextClipboard.normalize(RichTextPayload(
                    HtmlFragment: String(data: data, encoding: .utf8) ?? "",
                    PreferredFormat: "Html"
                ))
            )
        }
        DataRepresentation(importedContentType: .rtf) { data in
            MobileClipboardPayload(
                text: plainText(from: data, documentType: .rtf),
                richText: MobileRichTextClipboard.normalize(RichTextPayload(
                    RtfBase64: data.base64EncodedString(),
                    PreferredFormat: "Rtf"
                ))
            )
        }
        DataRepresentation(importedContentType: .plainText) { data in
            MobileClipboardPayload(
                text: String(data: data, encoding: .utf8) ?? "",
                richText: nil
            )
        }
    }

    private static func plainText(from data: Data, documentType: NSAttributedString.DocumentType) -> String {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: documentType,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        return (try? NSAttributedString(data: data, options: options, documentAttributes: nil).string) ?? ""
    }
}

enum MobileRichTextClipboard {
    private static let maxHTMLBytes = 768 * 1024
    private static let maxRTFBytes = 1024 * 1024
    private static let maxCombinedBytes = 1792 * 1024

    @MainActor
    static func containsText(in pasteboard: UIPasteboard = .general) -> Bool {
        pasteboard.contains(pasteboardTypes: [
            UTType.plainText.identifier,
            UTType.html.identifier,
            UTType.rtf.identifier
        ])
    }

    @MainActor
    static func readCurrent(in pasteboard: UIPasteboard = .general) -> MobileClipboardPayload? {
        guard containsText(in: pasteboard) else { return nil }
        let htmlData = pasteboard.data(forPasteboardType: UTType.html.identifier)
        let rtfData = pasteboard.data(forPasteboardType: UTType.rtf.identifier)
        let text = pasteboard.string
            ?? htmlData.map { plainText(from: $0, documentType: .html) }
            ?? rtfData.map { plainText(from: $0, documentType: .rtf) }
            ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let preferredFormat = htmlData == nil && rtfData != nil ? "Rtf" : "Html"
        let richText = normalize(RichTextPayload(
            HtmlFragment: htmlData.flatMap { String(data: $0, encoding: .utf8) } ?? "",
            RtfBase64: rtfData?.base64EncodedString() ?? "",
            PreferredFormat: preferredFormat
        ))
        return MobileClipboardPayload(text: text, richText: richText)
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
        return RichTextPayload(
            Version: 1,
            HtmlFragment: html,
            RtfBase64: rtf?.base64EncodedString() ?? "",
            PreferredFormat: requestedRTF && !(rtf?.isEmpty ?? true) ? "Rtf" : !html.isEmpty ? "Html" : "Rtf"
        )
    }

    @MainActor
    static func write(_ entry: ClipEntry, includeRichText: Bool, to pasteboard: UIPasteboard = .general) {
        var item: [String: Any] = [UTType.plainText.identifier: entry.Text]
        if includeRichText, let richText = normalize(entry.RichText) {
            if let html = richText.HtmlFragment.data(using: .utf8), !html.isEmpty {
                item[UTType.html.identifier] = html
            }
            if let rtf = Data(base64Encoded: richText.RtfBase64), !rtf.isEmpty {
                item[UTType.rtf.identifier] = rtf
            }
        }
        pasteboard.setItems([item])
    }

    private static func plainText(from data: Data, documentType: NSAttributedString.DocumentType) -> String {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: documentType,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        return (try? NSAttributedString(data: data, options: options, documentAttributes: nil).string) ?? ""
    }
}
