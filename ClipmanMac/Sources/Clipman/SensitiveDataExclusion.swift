import Foundation

struct SensitiveDataPreset: Hashable {
    let id: String
    let name: String
    let pattern: String
    let separatorsOptional: Bool
    let requireLuhn: Bool
}

enum SensitiveDataExclusion {
    static let modeOff = "Off"
    static let modeExclude = "Exclude"

    static let builtInPresets: [SensitiveDataPreset] = [
        SensitiveDataPreset(id: "credit-card", name: "Credit card number", pattern: "#{13,19}", separatorsOptional: true, requireLuhn: true),
        SensitiveDataPreset(id: "us-ssn", name: "US Social Security number", pattern: "###-##-####", separatorsOptional: true, requireLuhn: false),
        SensitiveDataPreset(id: "international-phone", name: "International phone number", pattern: "+###########", separatorsOptional: true, requireLuhn: false),
        SensitiveDataPreset(id: "api-token", name: "Long API key or token", pattern: "*{32,}", separatorsOptional: false, requireLuhn: false),
        SensitiveDataPreset(id: "software-license-key", name: "Software license key", pattern: "*{5}-*{5}-*{5}-*{5}-*{5}", separatorsOptional: false, requireLuhn: false),
        SensitiveDataPreset(id: "us-drivers-license", name: "US driver license, approximate", pattern: "@#{6,13}", separatorsOptional: false, requireLuhn: false)
    ]

    static func normalizeMode(_ value: String?) -> String {
        guard let value, value.caseInsensitiveCompare(modeExclude) == .orderedSame else { return modeOff }
        return modeExclude
    }

    static func matchName(in text: String, mode: String, presetIds: [String]) -> String? {
        guard normalizeMode(mode) == modeExclude, !text.isEmpty, !presetIds.isEmpty else { return nil }
        if isFullHTTPURL(text) { return nil }
        let enabled = Set(presetIds.map { $0.lowercased() })
        for preset in builtInPresets where enabled.contains(preset.id.lowercased()) {
            if matches(text, preset: preset) {
                return preset.name
            }
        }
        return nil
    }

    private static func matches(_ text: String, preset: SensitiveDataPreset) -> Bool {
        if preset.id == "international-phone" {
            return matchesInternationalPhone(text)
        }
        guard let regex = try? NSRegularExpression(pattern: compile(pattern: preset.pattern, separatorsOptional: preset.separatorsOptional)) else {
            return false
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        for match in regex.matches(in: text, range: range) {
            let value = nsText.substring(with: match.range)
            if !preset.requireLuhn || passesLuhn(value) {
                return true
            }
        }
        return false
    }

    private static func isFullHTTPURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    private static func matchesInternationalPhone(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9])\+[\d][\d\s().-]{6,20}\d(?![A-Za-z0-9])"#) else {
            return false
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        for match in regex.matches(in: text, range: range) {
            let value = nsText.substring(with: match.range)
            let digits = value.filter(\.isNumber)
            if digits.count >= 8 && digits.count <= 15 {
                return true
            }
        }
        return false
    }

    private static func compile(pattern: String, separatorsOptional: Bool) -> String {
        var output = #"(?<![A-Za-z0-9])"#
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let char = pattern[index]
            if "#@*.".contains(char) {
                let token = tokenRegex(char)
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "{", let end = pattern[next...].firstIndex(of: "}") {
                    let quantifier = String(pattern[next...end])
                    if let parsed = parseQuantifier(quantifier) {
                        output += quantifiedTokenRegex(token, min: parsed.min, max: parsed.max, separatorsOptional: separatorsOptional)
                        index = pattern.index(after: end)
                        continue
                    } else {
                        index = next
                    }
                } else {
                    index = next
                }
                output += token
                if separatorsOptional {
                    output += #"[ -]?"#
                }
                continue
            }
            if char.isWhitespace {
                output += separatorsOptional ? #"[ -]?"# : #"\s+"#
            } else {
                output += NSRegularExpression.escapedPattern(for: String(char))
            }
            index = pattern.index(after: index)
        }
        output += #"(?![A-Za-z0-9])"#
        return output
    }

    private static func quantifiedTokenRegex(_ token: String, min: Int, max: Int?, separatorsOptional: Bool) -> String {
        if !separatorsOptional {
            return "\(token){\(min),\(max.map(String.init) ?? "")}"
        }
        if min <= 1 {
            let suffix = max.map { "{0,\(Swift.max(0, $0 - 1))}" } ?? "*"
            return "\(token)(?:[ -]?\(token))\(suffix)"
        }
        let repeatMin = min - 1
        let repeatMax = max.map { String(Swift.max(0, $0 - 1)) } ?? ""
        return "\(token)(?:[ -]?\(token)){\(repeatMin),\(repeatMax)}"
    }

    private static func tokenRegex(_ token: Character) -> String {
        switch token {
        case "#": return #"\d"#
        case "@": return #"[A-Za-z]"#
        case "*": return #"[A-Za-z0-9]"#
        case ".": return #"."#
        default: return NSRegularExpression.escapedPattern(for: String(token))
        }
    }

    private static func parseQuantifier(_ text: String) -> (min: Int, max: Int?)? {
        guard let regex = try? NSRegularExpression(pattern: #"^\{(\d+)(?:[,-](\d*))?\}$"#) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) else { return nil }
        guard let minRange = Range(match.range(at: 1), in: text), let min = Int(text[minRange]), min > 0 else { return nil }
        if match.range(at: 2).location != NSNotFound,
           let maxRange = Range(match.range(at: 2), in: text),
           !text[maxRange].isEmpty {
            guard let max = Int(text[maxRange]), max >= min else { return nil }
            return (min, max)
        }
        if text.contains(",") || text.contains("-") {
            return (min, nil)
        }
        return (min, min)
    }

    private static func passesLuhn(_ text: String) -> Bool {
        let digits = text.compactMap { $0.wholeNumberValue }
        guard digits.count >= 13, digits.count <= 19 else { return false }
        var sum = 0
        var doubleDigit = false
        for value in digits.reversed() {
            var digit = value
            if doubleDigit {
                digit *= 2
                if digit > 9 { digit -= 9 }
            }
            sum += digit
            doubleDigit.toggle()
        }
        return sum % 10 == 0
    }
}
