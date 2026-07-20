import Foundation

enum ServerSettingsSanitizer {
    static func cleanDisplayURL(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let labeled = text.range(of: #"(?i)\b(?:Server address|Address|URL)\s*:\s*(\S+)"#, options: .regularExpression) {
            text = String(text[labeled])
                .replacingOccurrences(of: #"(?i)^.*:\s*"#, with: "", options: .regularExpression)
        }
        if let embedded = text.range(of: #"(?i)\b(?:clipman|https?)://[^\s,;]+"#, options: .regularExpression) {
            text = String(text[embedded])
        }
        if text.lowercased().hasPrefix("http://") {
            text = "clipman://" + text.dropFirst("http://".count)
        }
        if !text.contains("://") && !text.isEmpty {
            text = "clipman://" + text
        }
        if !text.hasSuffix("/") && !text.isEmpty {
            text += "/"
        }
        return text
    }

    static func cleanTransportURL(_ value: String) -> String {
        var text = cleanDisplayURL(value)
        if text.lowercased().hasPrefix("clipman://") {
            text = "http://" + text.dropFirst("clipman://".count)
        }
        return text
    }

    static func cleanToken(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = text.range(of: #"(?i)\b(?:Token|AuthToken)\s*[:=]\s*"?([A-Za-z0-9_\-]+)"#, options: .regularExpression) {
            return String(text[match])
                .replacingOccurrences(of: #"(?i)^.*[:=]\s*"?"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" \r\n\t"))
        }
        if let json = text.range(of: #""AuthToken"\s*:\s*"([^"]+)""#, options: .regularExpression) {
            return String(text[json])
                .replacingOccurrences(of: #"^.*:\s*""#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" \r\n\t"))
        }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "\" \r\n\t"))
    }
}
