import Foundation

enum URLTrackingCleaner {
    private static let htmlURLAttributePattern = #"(?i)(\b(?:href|src|action)\s*=\s*["'])(https?://[^"']+)(["'])"#
    private static let plainURLPattern = #"(?i)https?://[^\s<>'"]+"#
    private static let trailingURLPunctuation = CharacterSet(charactersIn: ".,);]!?")
    private static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "dclid", "msclkid", "gbraid", "wbraid", "igshid",
        "mc_cid", "mc_eid", "mkt_tok", "vero_id", "_hsenc", "_hsmi", "yclid",
        "twclid", "li_fat_id", "sc_cid", "oly_anon_id", "oly_enc_id",
        "rb_clickid", "spm", "ref", "ref_src"
    ]

    static func cleanText(_ text: String) -> String {
        clean(text, cleanShareState: false)
    }

    static func cleanForSharing(_ text: String) -> String {
        clean(text, cleanShareState: true)
    }

    private static func clean(_ text: String, cleanShareState: Bool) -> String {
        guard !text.isEmpty else { return "" }
        let htmlCleaned = replaceMatches(in: text, pattern: htmlURLAttributePattern) { match, source in
            guard match.numberOfRanges >= 4,
                  let prefixRange = Range(match.range(at: 1), in: source),
                  let urlRange = Range(match.range(at: 2), in: source),
                  let suffixRange = Range(match.range(at: 3), in: source)
            else { return nil }
            return String(source[prefixRange])
                + cleanURL(String(source[urlRange]), htmlAttribute: true, cleanShareState: cleanShareState)
                + String(source[suffixRange])
        }

        return replaceMatches(in: htmlCleaned, pattern: plainURLPattern) { match, source in
            guard let range = Range(match.range, in: source) else { return nil }
            var value = String(source[range])
            var trailing = ""
            while let scalar = value.unicodeScalars.last,
                  trailingURLPunctuation.contains(scalar) {
                trailing = String(Character(scalar)) + trailing
                value.removeLast()
            }
            return cleanURL(value, htmlAttribute: false, cleanShareState: cleanShareState) + trailing
        }
    }

    private static func replaceMatches(in text: String, pattern: String, transform: (NSTextCheckingResult, String) -> String?) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let replacement = transform(match, text),
                  let range = Range(match.range, in: result)
            else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private static func cleanURL(_ url: String, htmlAttribute: Bool, cleanShareState: Bool) -> String {
        guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return url }
        let parseURL = htmlAttribute ? decodeHTMLAmpersands(url) : url
        guard var components = URLComponents(string: parseURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let query = components.percentEncodedQuery,
              !query.isEmpty
        else { return url }

        let host = components.host ?? ""
        var changed = false
        let kept = query.split(separator: "&", omittingEmptySubsequences: true).compactMap { part -> String? in
            let value = String(part)
            let name = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? value
            if shouldRemoveParameter(name) || (cleanShareState && shouldRemoveShareParameter(name, host: host)) {
                changed = true
                return nil
            }
            return value
        }

        guard changed else { return url }
        components.percentEncodedQuery = kept.isEmpty ? nil : kept.joined(separator: "&")
        let cleaned = components.url?.absoluteString ?? url
        return htmlAttribute ? encodeHTMLAmpersands(cleaned) : cleaned
    }

    private static func shouldRemoveParameter(_ name: String) -> Bool {
        let decoded = decodeParameterName(name)
        if decoded.hasPrefix("utm_") || decoded.hasPrefix("hsa_") { return true }
        return trackingParameters.contains(decoded)
    }

    private static func shouldRemoveShareParameter(_ name: String, host: String) -> Bool {
        let decoded = decodeParameterName(name)
        if isYouTubeHost(host) {
            return ["t", "time_continue", "start", "pp", "si", "feature"].contains(decoded)
        }
        return decoded == "si"
    }

    private static func decodeParameterName(_ name: String) -> String {
        (name.removingPercentEncoding ?? name).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isYouTubeHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower == "youtu.be" || lower == "youtube.com" || lower.hasSuffix(".youtube.com")
    }

    private static func decodeHTMLAmpersands(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(of: "&#x26;", with: "&")
            .replacingOccurrences(of: "&#X26;", with: "&")
    }

    private static func encodeHTMLAmpersands(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
    }
}
