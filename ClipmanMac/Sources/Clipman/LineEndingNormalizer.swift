import Foundation

enum LineEndingStyle {
    case windows
    case unix
    case oldMac

    var separator: String {
        switch self {
        case .windows:
            return "\r\n"
        case .unix:
            return "\n"
        case .oldMac:
            return "\r"
        }
    }
}

enum LineEndingNormalizer {
    static func normalize(_ text: String, to style: LineEndingStyle) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{0085}", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\n", with: style.separator)
    }
}
