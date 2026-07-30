import Foundation
import CryptoKit
import Security

struct ServerConnectionDetails {
    let address: String
    let token: String
    let authority: ServerCertificateAuthority?
}

struct ServerCertificateAuthority: Equatable {
    let pem: String
    let host: String
    let der: Data
    let subject: String
    let expires: Date
    let fingerprint: String
}

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

    static func parseConnectionConfig(_ data: Data) throws -> ServerConnectionDetails {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["clipman"] as? String == "server-connection"
        else {
            throw ConnectionConfigError.invalidFile
        }
        let version: Int?
        if let number = object["version"] as? NSNumber {
            version = number.intValue
        } else if let text = object["version"] as? String {
            version = Int(text)
        } else {
            version = nil
        }
        guard version == 1 else { throw ConnectionConfigError.unsupportedVersion }

        var address = cleanURL(object["address"] as? String ?? "")
        if address.isEmpty,
           let host = object["host"] as? String,
           let port = object["port"] as? NSNumber {
            address = cleanURL("\(host):\(port.intValue)")
        }
        let token = cleanToken(object["token"] as? String ?? "")
        guard !address.isEmpty, !token.isEmpty else { throw ConnectionConfigError.missingDetails }
        let authority = try parseCertificateAuthority(object["ca_cert_pem"] as? String ?? "", address: address)
        return ServerConnectionDetails(address: address, token: token, authority: authority)
    }

    static func connectionConfigData(
        address addressValue: String,
        token tokenValue: String,
        caCertPEM: String = "",
        caHost: String = ""
    ) throws -> Data {
        let address = cleanURL(addressValue)
        let token = cleanToken(tokenValue)
        guard !address.isEmpty, !token.isEmpty else { throw ConnectionConfigError.missingDetails }
        guard let transport = URL(string: cleanTransportURL(address)), let host = transport.host else {
            throw ConnectionConfigError.invalidAddress
        }
        let port = transport.port ?? (transport.scheme?.lowercased() == "https" ? 443 : 80)
        let authority = try parseCertificateAuthority(caCertPEM, address: address)
        if let authority, !caHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           authority.host.caseInsensitiveCompare(caHost.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame {
            throw ConnectionConfigError.authorityHostMismatch
        }
        var object: [String: Any] = [
            "clipman": "server-connection",
            "version": 1,
            "address": address,
            "host": host,
            "port": port,
            "token": token
        ]
        if let authority {
            object["ca_cert_pem"] = authority.pem
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    static func parseCertificateAuthority(_ pemValue: String, address addressValue: String) throws -> ServerCertificateAuthority? {
        let pem = pemValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pem.isEmpty else { return nil }
        guard pem.lengthOfBytes(using: .utf8) <= 32 * 1024 else { throw ConnectionConfigError.authorityTooLarge }
        guard pem.range(of: "PRIVATE KEY", options: .caseInsensitive) == nil else {
            throw ConnectionConfigError.authorityContainsPrivateKey
        }
        let pattern = #"\A\s*-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\r\n]+?)\s*-----END CERTIFICATE-----\s*\z"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: pem, range: NSRange(pem.startIndex..., in: pem)),
              match.range == NSRange(pem.startIndex..., in: pem),
              let bodyRange = Range(match.range(at: 1), in: pem)
        else { throw ConnectionConfigError.invalidAuthority }
        let body = String(pem[bodyRange]).components(separatedBy: .whitespacesAndNewlines).joined()
        guard let der = Data(base64Encoded: body),
              let certificate = SecCertificateCreateWithData(nil, der as CFData)
        else { throw ConnectionConfigError.invalidAuthority }

        let address = cleanURL(addressValue)
        guard let url = URL(string: cleanTransportURL(address)),
              url.scheme?.caseInsensitiveCompare("https") == .orderedSame,
              let host = url.host, !host.isEmpty
        else { throw ConnectionConfigError.authorityRequiresHTTPS }

        let (notBefore, notAfter) = try authorityValidity(der)
        let now = Date()
        guard now >= notBefore else { throw ConnectionConfigError.authorityNotYetValid }
        guard now <= notAfter else { throw ConnectionConfigError.authorityExpired }

        let canonicalBody = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let canonicalPEM = "-----BEGIN CERTIFICATE-----\n\(canonicalBody)\n-----END CERTIFICATE-----\n"
        let digest = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
        let subject = SecCertificateCopySubjectSummary(certificate) as String? ?? "Unknown authority"
        return ServerCertificateAuthority(
            pem: canonicalPEM,
            host: host,
            der: der,
            subject: subject,
            expires: notAfter,
            fingerprint: digest
        )
    }

    private static func authorityValidity(_ der: Data) throws -> (Date, Date) {
        var certificateReader = DERReader(der)
        let certificate = try certificateReader.read(tag: 0x30)
        guard certificateReader.isAtEnd else { throw ConnectionConfigError.invalidAuthority }
        var certificateFields = DERReader(certificate.value)
        let tbsCertificate = try certificateFields.read(tag: 0x30)
        var fields = DERReader(tbsCertificate.value)
        if fields.peekTag == 0xA0 { _ = try fields.read() }
        _ = try fields.read(tag: 0x02)
        _ = try fields.read(tag: 0x30)
        _ = try fields.read(tag: 0x30)
        let validity = try fields.read(tag: 0x30)
        var validityFields = DERReader(validity.value)
        let notBefore = try parseCertificateTime(validityFields.read())
        let notAfter = try parseCertificateTime(validityFields.read())
        guard validityFields.isAtEnd else { throw ConnectionConfigError.invalidAuthority }
        _ = try fields.read(tag: 0x30)
        _ = try fields.read(tag: 0x30)

        var hasCAConstraint = false
        var certificateSigningUsage: Bool?
        while !fields.isAtEnd {
            let field = try fields.read()
            guard field.tag == 0xA3 else { continue }
            var explicitReader = DERReader(field.value)
            let extensions = try explicitReader.read(tag: 0x30)
            guard explicitReader.isAtEnd else { throw ConnectionConfigError.invalidAuthority }
            var extensionReader = DERReader(extensions.value)
            while !extensionReader.isAtEnd {
                let item = try extensionReader.read(tag: 0x30)
                var itemReader = DERReader(item.value)
                let oid = try itemReader.read(tag: 0x06).value
                if itemReader.peekTag == 0x01 { _ = try itemReader.read() }
                let encodedValue = try itemReader.read(tag: 0x04).value
                guard itemReader.isAtEnd else { throw ConnectionConfigError.invalidAuthority }
                if oid == Data([0x55, 0x1D, 0x13]) {
                    var constraintsReader = DERReader(encodedValue)
                    let constraints = try constraintsReader.read(tag: 0x30)
                    var values = DERReader(constraints.value)
                    if values.peekTag == 0x01 {
                        let ca = try values.read(tag: 0x01).value
                        hasCAConstraint = ca.count == 1 && ca[ca.startIndex] != 0
                    }
                } else if oid == Data([0x55, 0x1D, 0x0F]) {
                    var usageReader = DERReader(encodedValue)
                    let usage = try usageReader.read(tag: 0x03).value
                    guard usage.count >= 2 else { throw ConnectionConfigError.invalidAuthority }
                    certificateSigningUsage = usage[usage.index(after: usage.startIndex)] & 0x04 != 0
                }
            }
        }
        guard hasCAConstraint, certificateSigningUsage != false else {
            throw ConnectionConfigError.notCertificateAuthority
        }
        return (notBefore, notAfter)
    }

    private static func parseCertificateTime(_ node: DERNode) throws -> Date {
        guard node.tag == 0x17 || node.tag == 0x18,
              var text = String(data: node.value, encoding: .ascii),
              text.hasSuffix("Z")
        else { throw ConnectionConfigError.invalidAuthority }
        text.removeLast()
        if let fractional = text.firstIndex(of: ".") { text = String(text[..<fractional]) }
        let yearDigits = node.tag == 0x17 ? 2 : 4
        guard text.count == yearDigits + 10,
              let yearPart = Int(text.prefix(yearDigits)),
              let month = Int(text.dropFirst(yearDigits).prefix(2)),
              let day = Int(text.dropFirst(yearDigits + 2).prefix(2)),
              let hour = Int(text.dropFirst(yearDigits + 4).prefix(2)),
              let minute = Int(text.dropFirst(yearDigits + 6).prefix(2)),
              let second = Int(text.dropFirst(yearDigits + 8).prefix(2))
        else { throw ConnectionConfigError.invalidAuthority }
        let year = yearDigits == 2 ? (yearPart >= 50 ? 1900 + yearPart : 2000 + yearPart) : yearPart
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let date = components.date else { throw ConnectionConfigError.invalidAuthority }
        return date
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

private struct DERNode {
    let tag: UInt8
    let value: Data
}

private struct DERReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = data }

    var isAtEnd: Bool { offset == data.count }
    var peekTag: UInt8? { offset < data.count ? data[data.index(data.startIndex, offsetBy: offset)] : nil }

    mutating func read(tag expectedTag: UInt8? = nil) throws -> DERNode {
        guard offset < data.count else { throw ConnectionConfigError.invalidAuthority }
        let tag = readByte()
        if let expectedTag, tag != expectedTag { throw ConnectionConfigError.invalidAuthority }
        guard offset < data.count else { throw ConnectionConfigError.invalidAuthority }
        let firstLength = readByte()
        let length: Int
        if firstLength & 0x80 == 0 {
            length = Int(firstLength)
        } else {
            let byteCount = Int(firstLength & 0x7F)
            guard byteCount > 0, byteCount <= 4, offset + byteCount <= data.count else {
                throw ConnectionConfigError.invalidAuthority
            }
            var value = 0
            for _ in 0..<byteCount { value = (value << 8) | Int(readByte()) }
            length = value
        }
        guard length >= 0, offset + length <= data.count else { throw ConnectionConfigError.invalidAuthority }
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: length)
        offset += length
        return DERNode(tag: tag, value: data.subdata(in: start..<end))
    }

    private mutating func readByte() -> UInt8 {
        defer { offset += 1 }
        return data[data.index(data.startIndex, offsetBy: offset)]
    }
}

enum ConnectionConfigError: LocalizedError {
    case invalidFile
    case unsupportedVersion
    case missingDetails
    case fileTooLarge
    case invalidAddress
    case authorityTooLarge
    case authorityContainsPrivateKey
    case invalidAuthority
    case authorityRequiresHTTPS
    case notCertificateAuthority
    case authorityNotYetValid
    case authorityExpired
    case authorityHostMismatch

    var errorDescription: String? {
        switch self {
        case .invalidFile: return "This is not a Clipman Server connection file."
        case .unsupportedVersion: return "This Clipman Server connection-file version is not supported."
        case .missingDetails: return "The connection file does not contain both a server address and token."
        case .fileTooLarge: return "This connection file is too large."
        case .invalidAddress: return "The Clipman Server address is not valid."
        case .authorityTooLarge: return "The private certificate authority exceeds the 32 KiB limit."
        case .authorityContainsPrivateKey: return "The private certificate authority must not contain private key material."
        case .invalidAuthority: return "The private certificate authority must contain exactly one valid PEM CERTIFICATE block."
        case .authorityRequiresHTTPS: return "A private certificate authority can be used only with an HTTPS server address."
        case .notCertificateAuthority: return "The configured certificate is not a certificate authority that can sign certificates."
        case .authorityNotYetValid: return "The configured certificate authority is not valid yet."
        case .authorityExpired: return "The configured certificate authority has expired."
        case .authorityHostMismatch: return "The private certificate authority is configured for a different server host."
        }
    }
}
