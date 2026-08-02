import AppKit
import ClipmanCore

struct StandaloneImageInput: Sendable {
    let data: Data
    let filename: String
}

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

    static func standaloneImageInput(
        from pasteboard: NSPasteboard,
        preferredFilename: String? = nil
    ) -> Result<StandaloneImageInput, EmbeddedImageError>? {
        let candidates: [(type: NSPasteboard.PasteboardType, extensionName: String, convertTIFF: Bool)] = [
            (NSPasteboard.PasteboardType("public.png"), "png", false),
            (NSPasteboard.PasteboardType("public.jpeg"), "jpg", false),
            (NSPasteboard.PasteboardType("public.jpg"), "jpg", false),
            (.tiff, "tiff", true)
        ]
        for candidate in candidates {
            guard let data = pasteboard.data(forType: candidate.type) else { continue }
            guard data.count <= EmbeddedImageHTML.maxInputBytes else {
                return .failure(.inputTooLarge)
            }
            let suggestedName = preferredFilename?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? pasteboard.string(forType: NSPasteboard.PasteboardType("public.url-name"))
                ?? pasteboard.string(forType: NSPasteboard.PasteboardType("public.file-url")).flatMap { URL(string: $0)?.lastPathComponent }
                ?? "Clipboard image.\(candidate.extensionName)"
            if candidate.convertTIFF {
                do {
                    let png = try EmbeddedImageHTML.pngData(fromTIFFTransport: data)
                    return .success(StandaloneImageInput(data: png, filename: suggestedName))
                } catch let error as EmbeddedImageError {
                    return .failure(error)
                } catch {
                    return .failure(.invalidImage)
                }
            }
            return .success(StandaloneImageInput(data: data, filename: suggestedName))
        }
        return nil
    }

    static func localFileURLs(from pasteboard: NSPasteboard) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        guard pasteboard.canReadObject(forClasses: [NSURL.self], options: options) else {
            return nil
        }
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL]
        return objects?.map { $0 as URL } ?? []
    }

    @discardableResult
    static func write(
        _ payload: RichTextPayload?,
        to pasteboard: NSPasteboard,
        imageFilename: String? = nil
    ) -> EmbeddedImagePasteboardFile? {
        guard let payload = normalize(payload) else { return nil }
        if let html = payload.HtmlFragment.data(using: .utf8), !html.isEmpty {
            pasteboard.setData(html, forType: .html)
        }
        if let rtf = Data(base64Encoded: payload.RtfBase64), !rtf.isEmpty {
            pasteboard.setData(rtf, forType: .rtf)
        }
        if let image = EmbeddedImageHTML.imageInfo(from: payload) {
            let nativeType = image.mimeType == "image/png"
                ? NSPasteboard.PasteboardType("public.png")
                : NSPasteboard.PasteboardType("public.jpeg")
            pasteboard.setData(image.data, forType: nativeType)
            if let tiff = NSImage(data: image.data)?.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
            if let imageFilename {
                guard let temporaryFile = try? EmbeddedImagePasteboardFile(
                    data: image.data,
                    filename: imageFilename
                ), pasteboard.setString(temporaryFile.fileURL.absoluteString, forType: .fileURL)
                else {
                    return nil
                }
                return temporaryFile
            }
        }
        return nil
    }

    static func normalize(_ payload: RichTextPayload?) -> RichTextPayload? {
        guard let payload else { return nil }
        var html = payload.HtmlFragment
        if html.utf8.count > maxHTMLBytes { html = "" }
        if html.hasPrefix("<img data-clipman-image="), EmbeddedImageHTML.imageInfo(fromHTML: html) == nil {
            html = ""
        }
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

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
