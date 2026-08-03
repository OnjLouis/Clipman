import CoreFoundation
import Foundation

package enum WebsiteMetadataParser {
    private static let maximumMetadataCharacters = 128 * 1024
    private static let nonMetadataElements = ["script", "style", "template", "noscript", "svg", "iframe"]
    private static let exactJunkTitles = Set([
        "just a moment", "attention required", "access denied", "access to this page has been denied",
        "are you a robot", "are you a human", "please wait", "javascript is disabled",
        "javascript is required", "enable javascript", "security check", "checking your browser",
        "verify you are human", "human verification", "bot verification", "one moment please", "loading",
        "redirecting", "error", "page not found", "not found", "404", "403 forbidden", "forbidden",
        "site maintenance", "under construction", "untitled", "untitled document", "log in", "login",
        "sign in", "signin", "log in or sign up", "robot check", "captcha", "request blocked", "blocked",
        "reddit - dive into anything"
    ])
    private static let junkTitleFragments = [
        "please wait for verification", "checking if the site connection is secure",
        "enable javascript and cookies to continue", "verify you are a human",
        "your request has been blocked", "unusual traffic"
    ]

    package static func title(from data: Data, response: URLResponse, host: String) -> String? {
        guard let html = decode(data, response: response) else { return nil }
        return title(from: html, host: host)
    }

    package static func title(from html: String, host: String) -> String? {
        let metadata = retainedMetadata(from: html)
        var openGraph: String?
        var twitter: String?
        if let regex = try? NSRegularExpression(pattern: #"<meta\b[^>]{0,4096}>"#, options: [.caseInsensitive]) {
            let range = NSRange(metadata.startIndex..<metadata.endIndex, in: metadata)
            for match in regex.matches(in: metadata, range: range) {
                guard let tagRange = Range(match.range, in: metadata) else { continue }
                let attributes = parsedAttributes(String(metadata[tagRange]))
                let key = (attributes["property"] ?? attributes["name"] ?? attributes["itemprop"] ?? "")
                    .lowercased()
                guard let content = attributes["content"], !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                if key == "og:title", openGraph == nil { openGraph = content }
                if key == "twitter:title", twitter == nil { twitter = content }
            }
        }

        let documentTitle = firstCapture(#"<title\b[^>]{0,1024}>(.*?)</title\s*>"#, in: metadata)
        let heading = firstCapture(#"<h1\b[^>]{0,4096}>(.*?)</h1\s*>"#, in: metadata)
        for candidate in [openGraph, twitter, documentTitle, heading] {
            guard let value = candidate.flatMap(sanitizedRemoteText),
                  !isJunkTitle(value),
                  value.caseInsensitiveCompare(host) != .orderedSame
            else { continue }
            return value
        }
        return nil
    }

    private static func retainedMetadata(from html: String) -> String {
        let source = html as NSString
        let output = NSMutableString()
        var index = 0
        while index < source.length, output.length < maximumMetadataCharacters {
            if source.length - index >= 4,
               source.substring(with: NSRange(location: index, length: 4)) == "<!--" {
                let search = NSRange(location: index + 4, length: source.length - index - 4)
                let end = source.range(of: "-->", options: [], range: search)
                index = end.location == NSNotFound ? source.length : NSMaxRange(end)
                continue
            }
            if source.character(at: index) != 60 {
                let search = NSRange(location: index, length: source.length - index)
                let next = source.range(of: "<", options: [], range: search)
                let end = next.location == NSNotFound ? source.length : next.location
                append(source, range: NSRange(location: index, length: end - index), to: output)
                index = end
                continue
            }
            guard let tagEnd = findTagEnd(source, start: index) else { break }
            let tagRange = NSRange(location: index, length: tagEnd - index + 1)
            let tag = source.substring(with: tagRange)
            let parsed = parsedTagName(tag)
            if !parsed.closing,
               nonMetadataElements.contains(parsed.name),
               !tag.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/>") {
                let search = NSRange(location: tagEnd + 1, length: source.length - tagEnd - 1)
                let close = source.range(of: "</\(parsed.name)", options: [.caseInsensitive], range: search)
                if close.location == NSNotFound { break }
                guard let closeEnd = findTagEnd(source, start: close.location) else { break }
                index = closeEnd + 1
                continue
            }
            append(source, range: tagRange, to: output)
            index = tagEnd + 1
        }
        return output as String
    }

    private static func append(_ source: NSString, range: NSRange, to output: NSMutableString) {
        let remaining = maximumMetadataCharacters - output.length
        guard remaining > 0, range.length > 0 else { return }
        output.append(source.substring(with: NSRange(location: range.location, length: min(range.length, remaining))))
    }

    private static func findTagEnd(_ source: NSString, start: Int) -> Int? {
        var quote: unichar = 0
        guard start + 1 < source.length else { return nil }
        for index in (start + 1)..<source.length {
            let character = source.character(at: index)
            if quote != 0 {
                if character == quote { quote = 0 }
            } else if character == 34 || character == 39 {
                quote = character
            } else if character == 62 {
                return index
            }
        }
        return nil
    }

    private static func parsedTagName(_ tag: String) -> (name: String, closing: Bool) {
        var value = tag.dropFirst().drop(while: \.isWhitespace)
        let closing = value.first == "/"
        if closing { value = value.dropFirst().drop(while: \.isWhitespace) }
        let name = value.prefix { $0.isLetter || $0.isNumber || $0 == ":" || $0 == "-" }.lowercased()
        return (name, closing)
    }

    private static func firstCapture(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value)
        else { return nil }
        return String(value[range])
    }

    private static func parsedAttributes(_ tag: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s\"'=<>`]+))"#
        ) else { return [:] }
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        var result: [String: String] = [:]
        for match in regex.matches(in: tag, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
            let name = tag[nameRange].lowercased()
            for index in 2...4 where match.range(at: index).location != NSNotFound {
                if let valueRange = Range(match.range(at: index), in: tag) {
                    result[name] = String(tag[valueRange])
                    break
                }
            }
        }
        return result
    }

    private static func sanitizedRemoteText(_ source: String) -> String? {
        let withoutTags = source.replacingOccurrences(of: #"<[^>]{0,4096}>"#, with: " ", options: .regularExpression)
        let decoded = decodeEntities(withoutTags)
        guard let normalized = LinkDisplayTextSanitizer.normalizedTitle(decoded) else { return nil }
        let separators = CharacterSet(charactersIn: " |-\u{2013}\u{2014}\u{00B7}\u{00BB}<")
        let trimmed = normalized.trimmingCharacters(in: separators)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isJunkTitle(_ title: String) -> Bool {
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!|-\u{2013}\u{2014}"))
        let normalized = title.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: trim)
        return exactJunkTitles.contains(normalized) || junkTitleFragments.contains { normalized.contains($0) }
    }

    private static func decode(_ data: Data, response: URLResponse) -> String? {
        if data.starts(with: [0xef, 0xbb, 0xbf]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if data.starts(with: [0xff, 0xfe]) { return String(data: data, encoding: .utf16LittleEndian) }
        if data.starts(with: [0xfe, 0xff]) { return String(data: data, encoding: .utf16BigEndian) }
        if let name = response.textEncodingName,
           let encoding = stringEncoding(ianaName: name),
           let decoded = String(data: data, encoding: encoding) {
            return decoded
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
    }

    private static func stringEncoding(ianaName: String) -> String.Encoding? {
        let encoding = CFStringConvertIANACharSetNameToEncoding(ianaName as CFString)
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
    }

    private static func decodeEntities(_ value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"&(#x[0-9a-f]+|#[0-9]+|amp|apos|gt|lt|nbsp|quot);"#, options: .caseInsensitive) else {
            return value
        }
        var output = value
        for match in regex.matches(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)).reversed() {
            guard let whole = Range(match.range(at: 0), in: output),
                  let tokenRange = Range(match.range(at: 1), in: output) else { continue }
            let token = output[tokenRange].lowercased()
            let replacement: String
            switch token {
            case "amp": replacement = "&"
            case "apos": replacement = "'"
            case "gt": replacement = ">"
            case "lt": replacement = "<"
            case "nbsp": replacement = " "
            case "quot": replacement = "\""
            default:
                let numberText = token.hasPrefix("#x") ? String(token.dropFirst(2)) : String(token.dropFirst())
                let radix = token.hasPrefix("#x") ? 16 : 10
                replacement = UInt32(numberText, radix: radix).flatMap(UnicodeScalar.init).map(String.init) ?? ""
            }
            output.replaceSubrange(whole, with: replacement)
        }
        return output
    }
}
