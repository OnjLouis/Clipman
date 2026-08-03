import Foundation

public struct LinkPresentation: Equatable, Sendable {
    package static let maximumURLCharacters = 8_192

    public let label: String
    public let destination: String

    public init(label: String, destination: String) {
        self.label = label
        self.destination = destination
    }

    public var rowText: String {
        destination.caseInsensitiveCompare(label) == .orderedSame || destination.isEmpty
            ? label
            : "\(label); \(destination)"
    }

    public static func make(urlText: String, assignedName: String = "") -> LinkPresentation? {
        guard isURLTextWithinLimit(urlText) else { return nil }
        guard let candidate = linkOnlyURLText(urlText),
              let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "clipman"].contains(scheme),
              let rawHost = components.host,
              !rawHost.isEmpty
        else {
            return nil
        }

        let host = normalizedHost(rawHost)
        guard !host.isEmpty else { return nil }
        let destinationHost = components.port.map { "\(host):\($0)" } ?? host
        let pathSegments = meaningfulPathSegments(components.percentEncodedPath)
        let generatedLabel: String
        if let last = pathSegments.last {
            if isPureNumber(last), pathSegments.count > 1 {
                generatedLabel = capped("\(pathSegments[pathSegments.count - 2]) \(last)", limit: 100)
            } else {
                generatedLabel = capped(last, limit: 100)
            }
        } else {
            generatedLabel = destinationHost
        }

        let name = normalizedLabel(assignedName)
        return LinkPresentation(
            label: name.isEmpty ? generatedLabel : capped(name, limit: 200),
            destination: shortenedDestination(host: destinationHost, percentEncodedPath: components.percentEncodedPath)
        )
    }

    public static func searchableText(urlText: String, assignedName: String = "") -> String {
        guard let generated = make(urlText: urlText),
              let presentation = make(urlText: urlText, assignedName: assignedName)
        else {
            return [normalizedLabel(assignedName), LinkDisplayTextSanitizer.stripUnsafeScalars(urlText)]
                .joined(separator: "\n")
        }
        return [
            normalizedLabel(assignedName),
            generated.label,
            presentation.destination,
            LinkDisplayTextSanitizer.stripUnsafeScalars(urlText)
        ].joined(separator: "\n")
    }

    private static let documentExtensions = Set([
        "asp", "aspx", "doc", "docx", "htm", "html", "jpeg", "jpg", "md", "pdf",
        "php", "png", "ppt", "pptx", "rtf", "shtml", "text", "txt", "xls", "xlsx"
    ])

    private static let structuralSegments = Set([
        "a", "article", "default", "home", "index", "item", "p", "page", "post", "view"
    ])

    private static func normalizedHost(_ value: String) -> String {
        var host = LinkDisplayTextSanitizer.stripUnsafeScalars(value)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host
    }

    private static func meaningfulPathSegments(_ percentEncodedPath: String) -> [String] {
        let rawSegments = percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
        var result: [String] = []
        for raw in rawSegments {
            let encoded = String(raw)
            let decoded = encoded.removingPercentEncoding ?? encoded
            guard !isUUID(decoded), !isHighEntropy(decoded) else { continue }
            let cleaned = cleanPathSegment(decoded)
            guard !cleaned.isEmpty,
                  !structuralSegments.contains(cleaned.lowercased())
            else {
                continue
            }
            result.append(cleaned)
        }
        return result
    }

    private static func cleanPathSegment(_ value: String) -> String {
        var cleaned = sanitizedDisplayText(value).trimmingCharacters(in: .whitespacesAndNewlines)
        if let dot = cleaned.lastIndex(of: ".") {
            let ext = cleaned[cleaned.index(after: dot)...].lowercased()
            if documentExtensions.contains(ext) {
                cleaned = String(cleaned[..<dot])
            }
        }
        cleaned = cleaned
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        if cleaned == cleaned.lowercased(),
           let first = cleaned.first,
           first.isLetter {
            cleaned.replaceSubrange(cleaned.startIndex...cleaned.startIndex, with: String(first).uppercased())
        }
        return capped(cleaned, limit: 80)
    }

    private static func shortenedDestination(host: String, percentEncodedPath: String) -> String {
        let decodedPath = sanitizedDisplayText(percentEncodedPath.removingPercentEncoding ?? percentEncodedPath)
        let full = host + (decodedPath == "/" ? "" : decodedPath)
        guard full.count > 120 else { return full }
        let prefix = String(full.prefix(70))
        let suffix = String(full.suffix(45))
        return "\(prefix)...\(suffix)"
    }

    private static func sanitizedDisplayText(_ value: String) -> String {
        LinkDisplayTextSanitizer.stripUnsafeScalars(value)
    }

    private static func normalizedLabel(_ value: String) -> String {
        sanitizedDisplayText(value)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    package static func isURLTextWithinLimit(_ value: String) -> Bool {
        value.utf8.count <= maximumURLCharacters
    }

    public static func linkOnlyURLText(_ value: String) -> String? {
        guard isURLTextWithinLimit(value) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .newlines) == nil else { return nil }
        let candidate: String
        if let match = trimmed.range(
            of: #"\s+link$"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            candidate = String(trimmed[..<match.lowerBound])
        } else {
            candidate = trimmed
        }
        guard !candidate.isEmpty,
              candidate.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "clipman"].contains(scheme),
              components.host?.isEmpty == false else { return nil }
        return candidate
    }

    private static func isUUID(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func isHighEntropy(_ value: String) -> Bool {
        let compact = value.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        if compact.count >= 16,
           compact.range(of: #"^[0-9a-f]+$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        guard compact.count >= 24,
              compact.range(of: #"^[A-Za-z0-9+/=]+$"#, options: .regularExpression) != nil
        else {
            return false
        }
        let hasLetter = compact.contains(where: \.isLetter)
        let hasNumber = compact.contains(where: \.isNumber)
        return hasLetter && hasNumber
    }

    private static func isPureNumber(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy(\.isNumber)
    }

    private static func capped(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(max(1, limit - 3))) + "..."
    }
}

package enum LinkDisplayTextSanitizer {
    package static func stripUnsafeScalars(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { scalar in
            guard scalar.value != 0xFFFD else { return false }
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .lineSeparator, .paragraphSeparator:
                return false
            default:
                return true
            }
        }))
    }

    package static func normalizedTitle(_ value: String, maximumCharacters: Int = 200) -> String? {
        let collapsed = stripUnsafeScalars(value)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maximumCharacters else { return collapsed }
        return String(collapsed.prefix(max(1, maximumCharacters - 3))) + "..."
    }
}
