import CoreTransferable
import Foundation
import UIKit
import UniformTypeIdentifiers

struct MobileClipboardPayload: Transferable, Sendable {
    let text: String
    let richText: RichTextPayload?
    let importError: String?

    var embeddedImage: EmbeddedImage? {
        EmbeddedImageCodec.recognize(richText)
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .html) { data in
            payload(fromHTMLData: data)
        }
        DataRepresentation(importedContentType: .rtf) { data in
            MobileClipboardPayload(
                text: plainText(from: data, documentType: .rtf),
                richText: MobileRichTextClipboard.normalize(RichTextPayload(
                    RtfBase64: data.base64EncodedString(),
                    PreferredFormat: "Rtf"
                )),
                importError: nil
            )
        }
        DataRepresentation(importedContentType: .png) { data in
            imagePayload(from: data)
        }
        DataRepresentation(importedContentType: .jpeg) { data in
            imagePayload(from: data)
        }
        DataRepresentation(importedContentType: .plainText) { data in
            MobileClipboardPayload(
                text: String(data: data, encoding: .utf8) ?? "",
                richText: nil,
                importError: nil
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

    private static func imagePayload(from data: Data) -> MobileClipboardPayload {
        do {
            return try EmbeddedImageCodec.makePayload(data: data)
        } catch {
            return MobileClipboardPayload(text: "", richText: nil, importError: error.localizedDescription)
        }
    }

    static func payload(fromHTMLData data: Data) -> MobileClipboardPayload {
        let html = String(data: data, encoding: .utf8) ?? ""
        let richText = MobileRichTextClipboard.normalize(RichTextPayload(
            HtmlFragment: html,
            PreferredFormat: "Html"
        ))
        if let image = EmbeddedImageCodec.recognize(richText) {
            return MobileClipboardPayload(
                text: EmbeddedImageCodec.identityText(for: image),
                richText: richText,
                importError: nil
            )
        }
        return MobileClipboardPayload(
            text: plainText(from: data, documentType: .html),
            richText: richText,
            importError: nil
        )
    }
}

enum MobileRichTextClipboard {
    private static let maxHTMLBytes = 768 * 1024
    private static let maxRTFBytes = 1024 * 1024
    private static let maxCombinedBytes = 1792 * 1024

    @MainActor
    static func containsSupportedContent(includeImages: Bool, in pasteboard: UIPasteboard = .general) -> Bool {
        var types = [
            UTType.plainText.identifier,
            UTType.utf8PlainText.identifier,
            UTType.html.identifier,
            UTType.rtf.identifier
        ]
        if includeImages {
            types.append(UTType.png.identifier)
            types.append(UTType.jpeg.identifier)
        }
        return pasteboard.contains(pasteboardTypes: types)
    }

    @MainActor
    static func readCurrent(includeImages: Bool = false, in pasteboard: UIPasteboard = .general) -> MobileClipboardPayload? {
        guard containsSupportedContent(includeImages: includeImages, in: pasteboard) else { return nil }
        let htmlData = pasteboard.data(forPasteboardType: UTType.html.identifier)
        let rtfData = pasteboard.data(forPasteboardType: UTType.rtf.identifier)
        if includeImages,
           let htmlData,
           let html = String(data: htmlData, encoding: .utf8),
           let image = try? EmbeddedImageCodec.recognize(html: html) {
            return MobileClipboardPayload(
                text: EmbeddedImageCodec.identityText(for: image),
                richText: RichTextPayload(HtmlFragment: html, PreferredFormat: "Html"),
                importError: nil
            )
        }
        if includeImages, htmlData == nil, rtfData == nil,
           let imageData = pasteboard.data(forPasteboardType: UTType.png.identifier)
                ?? pasteboard.data(forPasteboardType: UTType.jpeg.identifier) {
            do {
                return try EmbeddedImageCodec.makePayload(data: imageData)
            } catch {
                return MobileClipboardPayload(text: "", richText: nil, importError: error.localizedDescription)
            }
        }
        let text = pasteboard.string
            ?? htmlData.map { plainText(from: $0, documentType: .html) }
            ?? rtfData.map { plainText(from: $0, documentType: .rtf) }
            ?? ""
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let preferredFormat = htmlData == nil && rtfData != nil ? "Rtf" : "Html"
            let richText = normalize(RichTextPayload(
                HtmlFragment: htmlData.flatMap { String(data: $0, encoding: .utf8) } ?? "",
                RtfBase64: rtfData?.base64EncodedString() ?? "",
                PreferredFormat: preferredFormat
            ))
            return MobileClipboardPayload(text: text, richText: richText, importError: nil)
        }
        guard includeImages else { return nil }
        let imageData = pasteboard.data(forPasteboardType: UTType.png.identifier)
            ?? pasteboard.data(forPasteboardType: UTType.jpeg.identifier)
        guard let imageData else { return nil }
        do {
            return try EmbeddedImageCodec.makePayload(data: imageData)
        } catch {
            return MobileClipboardPayload(text: "", richText: nil, importError: error.localizedDescription)
        }
    }

    static func normalize(_ payload: RichTextPayload?) -> RichTextPayload? {
        guard let payload else { return nil }
        var html = payload.HtmlFragment
        if html.utf8.count > maxHTMLBytes { html = "" }
        if html.contains("data-clipman-image") {
            guard (try? EmbeddedImageCodec.recognize(html: html)) != nil else { return nil }
        }
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
        var item: [String: Any] = [
            UTType.plainText.identifier: entry.Text,
            UTType.utf8PlainText.identifier: entry.Text.data(using: .utf8) ?? Data()
        ]
        if let richText = normalize(entry.RichText),
           let image = EmbeddedImageCodec.recognize(richText) {
            item[image.mimeType == "image/png" ? UTType.png.identifier : UTType.jpeg.identifier] = image.data
            if let html = richText.HtmlFragment.data(using: .utf8), !html.isEmpty {
                item[UTType.html.identifier] = html
            }
        } else if includeRichText, let richText = normalize(entry.RichText) {
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
