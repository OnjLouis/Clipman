import Foundation
import UniformTypeIdentifiers

struct ServerConnectionDetails: Sendable {
    let address: String
    let token: String
}

extension UTType {
    static let clipmanServerConnection = UTType(
        exportedAs: "me.onj.clipman.server-connection",
        conformingTo: .json
    )
}

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
        if let json = text.range(of: #""(?:AuthToken|token)"\s*:\s*"([^"]+)""#, options: [.regularExpression, .caseInsensitive]) {
            return String(text[json])
                .replacingOccurrences(of: #"^.*:\s*""#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" \r\n\t"))
        }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "\" \r\n\t"))
    }

    static func parseConnectionConfig(_ data: Data) throws -> ServerConnectionDetails {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["clipman"] as? String == "server-connection"
        else { throw ConnectionConfigError.invalidFile }
        let version = (object["version"] as? NSNumber)?.intValue
            ?? Int(object["version"] as? String ?? "")
        guard version == 1 else { throw ConnectionConfigError.unsupportedVersion }

        var address = cleanDisplayURL(object["address"] as? String ?? "")
        if address.isEmpty,
           let host = object["host"] as? String,
           let port = object["port"] as? NSNumber {
            address = cleanDisplayURL("\(host):\(port.intValue)")
        }
        let token = cleanToken(object["token"] as? String ?? "")
        guard !address.isEmpty, !token.isEmpty else { throw ConnectionConfigError.missingDetails }
        return ServerConnectionDetails(address: address, token: token)
    }
}

enum ConnectionConfigError: LocalizedError, Sendable {
    case invalidFile
    case unsupportedVersion
    case missingDetails
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidFile: return "This is not a Clipman Server connection file."
        case .unsupportedVersion: return "This Clipman Server connection-file version is not supported."
        case .missingDetails: return "The connection file does not contain both a server address and token."
        case .fileTooLarge: return "This connection file is too large."
        }
    }
}
