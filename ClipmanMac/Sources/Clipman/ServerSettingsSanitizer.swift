import Foundation

enum ServerSettingsSanitizer {
    static func cleanURL(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        if let extracted = extractJSONValue(from: text, keys: ["ServerUrl", "serverUrl", "ListenPrefix", "listenPrefix", "url"]) {
            text = extracted
        } else if let urlRange = text.range(of: #"(https?|clipman)://[^\s,"']+"#, options: .regularExpression) {
            text = String(text[urlRange])
        } else if let hostRange = text.range(of: #"[A-Za-z0-9._-]+:\d{2,5}"#, options: .regularExpression) {
            text = String(text[hostRange])
        }

        text = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"',.;)")))
        let lower = text.lowercased()
        if lower.hasPrefix("http://") {
            text = "clipman://" + String(text.dropFirst("http://".count))
        } else if !lower.hasPrefix("clipman://") && !lower.hasPrefix("https://") {
            text = "clipman://" + text
        }
        while text.hasSuffix("/") {
            text.removeLast()
        }
        return text
    }

    static func cleanTransportURL(_ value: String) -> String {
        let cleaned = cleanURL(value)
        if cleaned.lowercased().hasPrefix("clipman://") {
            return "http://" + String(cleaned.dropFirst("clipman://".count))
        }
        return cleaned
    }

    static func cleanToken(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if let extracted = extractJSONValue(from: text, keys: ["ServerToken", "serverToken", "AuthToken", "authToken", "token"]) {
            text = extracted
        }
        return text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"',;")))
    }

    private static func extractJSONValue(from text: String, keys: [String]) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in keys {
            if let value = object[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }
}
