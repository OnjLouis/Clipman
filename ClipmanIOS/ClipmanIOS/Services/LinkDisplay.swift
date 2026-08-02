import Foundation

enum LinkPresentationSafety {
    static let maximumURLScalars = 8192

    static func isWithinURLLimit(_ value: String) -> Bool {
        value.unicodeScalars.prefix(maximumURLScalars + 1).count <= maximumURLScalars
    }

    static func cleanedText(_ value: String, maximumScalars: Int? = nil) -> String {
        var result = String.UnicodeScalarView()
        var pendingSpace = false

        for scalar in value.unicodeScalars {
            let category = scalar.properties.generalCategory
            if scalar.value == 0xFFFD || category == .control || category == .format ||
                category == .surrogate || category == .lineSeparator || category == .paragraphSeparator {
                continue
            }
            if scalar.properties.isWhitespace {
                pendingSpace = !result.isEmpty
                continue
            }
            if pendingSpace {
                if let maximumScalars, result.count >= maximumScalars { break }
                result.append(" ")
                pendingSpace = false
            }
            if let maximumScalars, result.count >= maximumScalars { break }
            result.append(scalar)
        }
        return String(result)
    }
}

struct LinkDisplayInfo: Equatable, Sendable {
    let generatedLabel: String
    let shortenedDestination: String
}

enum LinkDisplay {
    private static let genericSegments: Set<String> = [
        "default", "home", "index", "index.htm", "index.html", "index.php"
    ]

    static func info(for url: URL) -> LinkDisplayInfo {
        guard LinkPresentationSafety.isWithinURLLimit(url.absoluteString) else {
            return LinkDisplayInfo(generatedLabel: "Link", shortenedDestination: "Link")
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let host = displayHost(components?.host ?? url.host ?? "Link")
        let decodedSegments = (components?.percentEncodedPath ?? url.path)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { LinkPresentationSafety.cleanedText(String($0).removingPercentEncoding ?? String($0)) }
            .filter { !$0.isEmpty }
        let meaningfulIndex = decodedSegments.indices.reversed().first {
            isMeaningfulSegment(decodedSegments[$0])
        }
        let label = meaningfulIndex.map { index in
            var result = humanize(decodedSegments[index])
            if decodedSegments[index].allSatisfy(\.isNumber), index > decodedSegments.startIndex {
                let preceding = decodedSegments.index(before: index)
                if isMeaningfulSegment(decodedSegments[preceding]),
                   !decodedSegments[preceding].allSatisfy(\.isNumber) {
                    result = "\(humanize(decodedSegments[preceding])) \(result)"
                }
            }
            return result
        } ?? host

        let decodedPath = decodedSegments.joined(separator: "/")
        let destination = decodedPath.isEmpty ? host : "\(host)/\(decodedPath)"
        return LinkDisplayInfo(
            generatedLabel: label,
            shortenedDestination: shortened(destination, maximumLength: 96)
        )
    }

    static func rowText(for url: URL, name: String) -> String {
        let info = info(for: url)
        let explicitName = LinkPresentationSafety.cleanedText(name)
        if !explicitName.isEmpty {
            return "\(explicitName); \(info.shortenedDestination)"
        }
        let host = displayHost(url.host ?? "Link")
        if info.generatedLabel.caseInsensitiveCompare(host) == .orderedSame {
            return info.shortenedDestination
        }
        return "\(info.generatedLabel); \(info.shortenedDestination)"
    }

    private static func displayHost(_ value: String) -> String {
        var host = LinkPresentationSafety.cleanedText(value).lowercased()
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host.isEmpty ? "Link" : host
    }

    private static func isMeaningfulSegment(_ raw: String) -> Bool {
        let value = LinkPresentationSafety.cleanedText(raw)
        guard !value.isEmpty else { return false }
        let lower = value.lowercased()
        guard !genericSegments.contains(lower), !looksLikeUUID(lower), !looksHighEntropy(lower) else {
            return false
        }
        return true
    }

    private static func humanize(_ raw: String) -> String {
        var value = LinkPresentationSafety.cleanedText(raw)
        for suffix in [".html", ".htm", ".php", ".aspx"] where value.lowercased().hasSuffix(suffix) {
            value.removeLast(suffix.count)
            break
        }
        value = value.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        value = LinkPresentationSafety.cleanedText(value)
        guard let first = value.first else { return "" }
        return String(first).uppercased() + value.dropFirst()
    }

    private static func looksLikeUUID(_ value: String) -> Bool {
        if UUID(uuidString: value) != nil { return true }
        let compact = value.replacingOccurrences(of: "-", with: "")
        return compact.count == 32 && compact.allSatisfy(\.isHexDigit)
    }

    private static func looksHighEntropy(_ value: String) -> Bool {
        guard value.count >= 20 else { return false }
        if value.allSatisfy(\.isHexDigit) { return true }
        guard !value.contains("-"), !value.contains("_"), !value.contains(" ") else { return false }
        let scalars = value.unicodeScalars
        guard scalars.allSatisfy({
            CharacterSet.alphanumerics.contains($0) || $0 == "+" || $0 == "/" || $0 == "="
        }) else { return false }
        let distinct = Set(scalars).count
        let hasLetter = scalars.contains { CharacterSet.letters.contains($0) }
        let hasDigit = scalars.contains { CharacterSet.decimalDigits.contains($0) }
        return hasLetter && hasDigit && Double(distinct) / Double(scalars.count) >= 0.45
    }

    private static func shortened(_ value: String, maximumLength: Int) -> String {
        let safeValue = LinkPresentationSafety.cleanedText(value)
        guard safeValue.count > maximumLength else { return safeValue }
        let headCount = max(1, maximumLength - 3)
        return String(safeValue.prefix(headCount)) + "..."
    }
}
