import Foundation

public enum MultipleEntrySeparator {
    public static func normalize(_ value: String?) -> String {
        switch (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "none": return "None"
        case "newline": return "NewLine"
        case "space": return "Space"
        case "commaspace": return "CommaSpace"
        case "custom": return "Custom"
        default: return "BlankLine"
        }
    }

    public static func resolve(mode: String, custom: String) -> String {
        switch normalize(mode) {
        case "None": return ""
        case "NewLine": return "\n"
        case "Space": return " "
        case "CommaSpace": return ", "
        case "Custom":
            return custom
                .replacingOccurrences(of: "\\r\\n", with: "\r\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\t", with: "\t")
        default: return "\n\n"
        }
    }
}
