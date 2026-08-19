import Foundation

enum HTMLEntityDecoder {
    static func decode(_ value: String) -> String {
        var output = value
            .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
            .replacingOccurrences(of: "&apos;", with: "'", options: .caseInsensitive)
            .replacingOccurrences(of: "&#39;", with: "'", options: .caseInsensitive)
            .replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
            .replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
            .replacingOccurrences(of: "&nbsp;", with: " ", options: .caseInsensitive)
        guard let regex = try? NSRegularExpression(
            pattern: "&#(x[0-9a-f]+|[0-9]+);",
            options: [.caseInsensitive]
        ) else {
            return output
        }
        for match in regex.matches(
            in: output,
            range: NSRange(output.startIndex..., in: output)
        ).reversed() {
            guard let whole = Range(match.range(at: 0), in: output),
                  let numberRange = Range(match.range(at: 1), in: output) else {
                continue
            }
            let token = String(output[numberRange])
            let radix = token.lowercased().hasPrefix("x") ? 16 : 10
            let digits = radix == 16 ? String(token.dropFirst()) : token
            guard let scalarValue = UInt32(digits, radix: radix),
                  let scalar = UnicodeScalar(scalarValue) else {
                continue
            }
            output.replaceSubrange(whole, with: String(scalar))
        }
        return output
    }
}
