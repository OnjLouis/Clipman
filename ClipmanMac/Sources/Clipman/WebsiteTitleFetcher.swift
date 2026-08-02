import CoreFoundation
import ClipmanCore
import Darwin
import Foundation

enum WebsiteTitleFetchError: Error, LocalizedError, Sendable {
    case invalidURL
    case unsupportedScheme
    case userInfo
    case nonDefaultPort
    case localDestination
    case capabilityURL
    case cannotResolve
    case redirectLimit
    case insecureRedirect
    case authenticationRequired
    case responseStatus(Int)
    case nonHTML
    case bodyTooLarge
    case timedOut
    case noUsefulTitle
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "This entry is not a valid website URL."
        case .unsupportedScheme: return "Only public HTTP and HTTPS website links can be contacted."
        case .userInfo: return "Links containing a user name or password cannot be contacted."
        case .nonDefaultPort: return "Website titles can be read only from the standard HTTP or HTTPS port."
        case .localDestination: return "Local, private, link-local, and other non-public destinations cannot be contacted."
        case .capabilityURL: return "This looks like a sign-in, reset, confirmation, token, secret, or signed link, so Clipman will not contact it."
        case .cannotResolve: return "The website address could not be resolved to a validated public destination."
        case .redirectLimit: return "The website redirected more than three times."
        case .insecureRedirect: return "The website tried to redirect from HTTPS to insecure HTTP."
        case .authenticationRequired: return "The website requires authentication, so Clipman did not use its title."
        case .responseStatus(let status): return "The website returned HTTP status \(status)."
        case .nonHTML: return "The link did not return an HTML page."
        case .bodyTooLarge: return "The website title was not found within the 128 KiB response limit."
        case .timedOut: return "The website did not respond within eight seconds."
        case .noUsefulTitle: return "The website did not provide a useful page title."
        case .transport(let message): return message
        }
    }
}

struct ValidatedNumericAddress: Sendable, Hashable {
    let value: String

    fileprivate init(_ value: String) {
        self.value = value
    }
}

struct ValidatedLinkTarget: Sendable {
    let url: URL
    let originalHost: String
    let port: UInt16
    let numericAddresses: [ValidatedNumericAddress]
}

private final class AddressResolutionResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<[ValidatedNumericAddress], Error>?

    func store(_ result: Result<[ValidatedNumericAddress], Error>) {
        lock.lock()
        value = result
        lock.unlock()
    }

    func load() -> Result<[ValidatedNumericAddress], Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

enum LinkFetchSafety {
    static func validatedURL(_ text: String, resolveHost: Bool) throws -> URL {
        guard LinkPresentation.isURLTextWithinLimit(text) else {
            throw WebsiteTitleFetchError.invalidURL
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !host.isEmpty,
              let url = components.url
        else {
            throw WebsiteTitleFetchError.invalidURL
        }
        guard scheme == "http" || scheme == "https" else { throw WebsiteTitleFetchError.unsupportedScheme }
        guard components.user == nil, components.password == nil else { throw WebsiteTitleFetchError.userInfo }
        if let port = components.port {
            guard (scheme == "http" && port == 80) || (scheme == "https" && port == 443) else {
                throw WebsiteTitleFetchError.nonDefaultPort
            }
        }
        guard !isLocalHostName(host) else { throw WebsiteTitleFetchError.localDestination }
        guard !looksLikeCapabilityURL(components) else { throw WebsiteTitleFetchError.capabilityURL }
        if let literal = WebsiteAddressSafety.parseLiteralAddress(host) {
            guard WebsiteAddressSafety.isGlobalAddress(literal) else { throw WebsiteTitleFetchError.localDestination }
        } else if resolveHost {
            _ = try resolvedPublicAddresses(host, deadline: nil)
        }
        return url
    }

    static func validatedTarget(_ text: String, deadline: MonotonicDeadline) throws -> ValidatedLinkTarget {
        let url = try validatedURL(text, resolveHost: false)
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !host.isEmpty
        else {
            throw WebsiteTitleFetchError.invalidURL
        }
        let port = UInt16(components.port ?? (scheme == "https" ? 443 : 80))
        return ValidatedLinkTarget(
            url: url,
            originalHost: host,
            port: port,
            numericAddresses: try resolvedPublicAddresses(host, deadline: deadline)
        )
    }

    private static func isLocalHostName(_ host: String) -> Bool {
        let lower = host.lowercased()
        if !lower.contains("."), WebsiteAddressSafety.parseLiteralAddress(lower) == nil { return true }
        return ["localhost", ".localhost", ".local", ".lan", ".internal", ".home", ".home.arpa", ".localdomain"]
            .contains { lower == $0 || lower.hasSuffix($0) }
    }

    private static func looksLikeCapabilityURL(_ components: URLComponents) -> Bool {
        let sensitiveWords = [
            "activate", "authorization", "authorize", "callback", "confirm", "credential",
            "invite", "login", "logout", "magic", "oauth", "password", "recover", "recovery",
            "reset", "secret", "session", "signin", "sign-in", "signed", "sso", "token",
            "unsubscribe", "verify"
        ]
        let pathAndFragment = [components.percentEncodedPath, components.percentEncodedFragment ?? ""]
            .joined(separator: "/")
            .removingPercentEncoding?
            .lowercased() ?? components.percentEncodedPath.lowercased()
        let pathTokens = pathAndFragment.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if pathTokens.contains(where: { sensitiveWords.contains($0) }) { return true }
        if pathTokens.contains(where: isOpaqueToken) { return true }

        let sensitiveQueryNames = [
            "access_token", "apikey", "api_key", "auth", "code", "credential", "jwt", "key",
            "nonce", "otp", "passcode", "password", "secret", "session", "sig", "signature",
            "sso", "ticket", "token"
        ]
        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
            if sensitiveQueryNames.contains(where: { name == $0 || name.hasSuffix("_\($0)") || name.hasSuffix("-\($0)") }) {
                return true
            }
            if name.hasPrefix("x-amz-") || name.hasPrefix("x-goog-") { return true }
            if let value = item.value, isOpaqueToken(value) { return true }
        }
        return false
    }

    private static func isOpaqueToken(_ value: String) -> Bool {
        let compact = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count >= 24 else { return false }
        if compact.range(of: #"^[0-9a-f]{24,}$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        guard compact.range(of: #"^[A-Za-z0-9_\-+/=]+$"#, options: .regularExpression) != nil else { return false }
        return compact.contains(where: \.isLetter) && compact.contains(where: \.isNumber)
    }

    private static func resolvedPublicAddresses(_ host: String, deadline: MonotonicDeadline?) throws -> [ValidatedNumericAddress] {
        if let literal = WebsiteAddressSafety.parseLiteralAddress(host) {
            guard WebsiteAddressSafety.isGlobalAddress(literal) else { throw WebsiteTitleFetchError.localDestination }
            guard let canonical = WebsiteAddressSafety.canonicalNumericAddress(host) else { throw WebsiteTitleFetchError.cannotResolve }
            return [ValidatedNumericAddress(canonical)]
        }
        guard let deadline else { return try resolvedPublicAddressesSynchronously(host) }
        guard !deadline.isExpired else { throw WebsiteTitleFetchError.timedOut }
        let result = AddressResolutionResult()
        let signal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            result.store(Result { try resolvedPublicAddressesSynchronously(host) })
            signal.signal()
        }
        guard signal.wait(timeout: deadline.dispatchTime) == .success,
              let resolved = result.load()
        else {
            throw WebsiteTitleFetchError.timedOut
        }
        return try resolved.get()
    }

    private static func resolvedPublicAddressesSynchronously(_ host: String) throws -> [ValidatedNumericAddress] {

        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            throw WebsiteTitleFetchError.cannotResolve
        }
        defer { freeaddrinfo(first) }

        var addresses: [(bytes: [UInt8], numeric: String)] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            if current.pointee.ai_family == AF_INET,
               let socketAddress = current.pointee.ai_addr,
               let numeric = numericAddress(socketAddress, length: current.pointee.ai_addrlen) {
                let address = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var value = address
                addresses.append((withUnsafeBytes(of: &value) { Array($0) }, numeric))
            } else if current.pointee.ai_family == AF_INET6,
                      let socketAddress = current.pointee.ai_addr,
                      let numeric = numericAddress(socketAddress, length: current.pointee.ai_addrlen) {
                let address = socketAddress.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                var value = address
                addresses.append((withUnsafeBytes(of: &value) { Array($0) }, numeric))
            }
            cursor = current.pointee.ai_next
        }
        guard !addresses.isEmpty else { throw WebsiteTitleFetchError.cannotResolve }
        guard addresses.allSatisfy({ WebsiteAddressSafety.isGlobalAddress($0.bytes) }) else { throw WebsiteTitleFetchError.localDestination }
        var seen = Set<String>()
        return addresses.compactMap {
            seen.insert($0.numeric).inserted ? ValidatedNumericAddress($0.numeric) : nil
        }
    }

    private static func numericAddress(_ address: UnsafePointer<sockaddr>, length: socklen_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
        return status == 0 ? string(fromCStringBuffer: buffer) : nil
    }

    private static func string(fromCStringBuffer buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

}

enum WebsiteTitleParser {
    static func title(from data: Data, response: URLResponse) -> String? {
        guard let html = decode(data, response: response) else { return nil }
        let cleaned = removingNonMetadataBlocks(html)
        var openGraph: String?
        var twitter: String?

        if let metaRegex = try? NSRegularExpression(pattern: #"<meta\b[^>]{0,4096}>"#, options: [.caseInsensitive]) {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            for match in metaRegex.matches(in: cleaned, range: range) {
                guard let tagRange = Range(match.range, in: cleaned) else { continue }
                let attributes = parsedAttributes(String(cleaned[tagRange]))
                let key = (attributes["property"] ?? attributes["name"] ?? "").lowercased()
                guard let content = attributes["content"] else { continue }
                if key == "og:title", openGraph == nil { openGraph = content }
                if key == "twitter:title", twitter == nil { twitter = content }
            }
        }

        var documentTitle: String?
        if let titleRegex = try? NSRegularExpression(
            pattern: #"<title\b[^>]{0,1024}>(.*?)</title\s*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            if let match = titleRegex.firstMatch(in: cleaned, range: range),
               let titleRange = Range(match.range(at: 1), in: cleaned) {
                documentTitle = String(cleaned[titleRange])
            }
        }

        for candidate in [openGraph, twitter, documentTitle] {
            if let value = candidate.flatMap(sanitizedRemoteText), !isMisleadingLoginTitle(value) {
                return value
            }
        }
        return nil
    }

    private static func decode(_ data: Data, response: URLResponse) -> String? {
        if data.starts(with: [0xef, 0xbb, 0xbf]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.starts(with: [0xff, 0xfe]) { return String(data: data, encoding: .utf16LittleEndian) }
        if data.starts(with: [0xfe, 0xff]) { return String(data: data, encoding: .utf16BigEndian) }
        if let name = response.textEncodingName,
           let encoding = stringEncoding(ianaName: name),
           let decoded = String(data: data, encoding: encoding) {
            return decoded
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
    }

    private static func stringEncoding(ianaName: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(ianaName as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    private static func removingNonMetadataBlocks(_ html: String) -> String {
        var value = html
        for pattern in [#"<!--[\s\S]*?-->"#, #"<script\b[\s\S]*?</script\s*>"#, #"<style\b[\s\S]*?</style\s*>"#] {
            value = value.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return value
    }

    private static func parsedAttributes(_ tag: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s\"'=<>`]+))"#
        ) else { return [:] }
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        var result: [String: String] = [:]
        for match in regex.matches(in: tag, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
            let name = tag[nameRange].lowercased()
            for index in 2...4 where match.range(at: index).location != NSNotFound {
                if let valueRange = Range(match.range(at: index), in: tag) {
                    result[name] = String(tag[valueRange])
                    break
                }
            }
        }
        return result
    }

    private static func sanitizedRemoteText(_ source: String) -> String? {
        let withoutTags = source.replacingOccurrences(of: #"<[^>]{0,1024}>"#, with: " ", options: .regularExpression)
        let decoded = decodeEntities(withoutTags)
        return LinkDisplayTextSanitizer.normalizedTitle(decoded)
    }

    private static func decodeEntities(_ value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"&(#x[0-9a-f]+|#[0-9]+|amp|apos|gt|lt|nbsp|quot);"#, options: .caseInsensitive) else {
            return value
        }
        var output = value
        let matches = regex.matches(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)).reversed()
        for match in matches {
            guard let whole = Range(match.range(at: 0), in: output),
                  let tokenRange = Range(match.range(at: 1), in: output)
            else { continue }
            let token = output[tokenRange].lowercased()
            let replacement: String
            switch token {
            case "amp": replacement = "&"
            case "apos": replacement = "'"
            case "gt": replacement = ">"
            case "lt": replacement = "<"
            case "nbsp": replacement = " "
            case "quot": replacement = "\""
            default:
                let numberText = token.hasPrefix("#x") ? String(token.dropFirst(2)) : String(token.dropFirst())
                let radix = token.hasPrefix("#x") ? 16 : 10
                if let number = UInt32(numberText, radix: radix), let scalar = UnicodeScalar(number) {
                    replacement = String(scalar)
                } else {
                    replacement = ""
                }
            }
            output.replaceSubrange(whole, with: replacement)
        }
        return output
    }

    private static func isMisleadingLoginTitle(_ title: String) -> Bool {
        let normalized = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["access denied", "authentication required", "just a moment", "log in", "login", "sign in", "signin"]
            .contains(normalized)
    }
}

final class WebsiteTitleFetcher: @unchecked Sendable {
    private static let maxBodyBytes = 128 * 1024

    static func fetch(urlText: String, completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result: Result<String, Error>
            do {
                result = .success(try fetchTitle(urlText: urlText))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func fetchTitle(urlText: String) throws -> String {
        let deadline = MonotonicDeadline(timeoutSeconds: 8)
        var target = try LinkFetchSafety.validatedTarget(urlText, deadline: deadline)
        var redirectCount = 0
        while true {
            guard !deadline.isExpired else { throw WebsiteTitleFetchError.timedOut }
            let received = try PinnedHTTPTransport.get(
                target: target,
                deadline: deadline,
                maximumDecodedBodyBytes: maxBodyBytes
            )
            let status = received.response.statusCode
            if [301, 302, 303, 307, 308].contains(status) {
                redirectCount += 1
                guard redirectCount <= 3 else { throw WebsiteTitleFetchError.redirectLimit }
                guard let location = received.response.value(forHTTPHeaderField: "location"),
                      LinkPresentation.isURLTextWithinLimit(location),
                      let redirectURL = URL(string: location, relativeTo: target.url)?.absoluteURL
                else {
                    throw WebsiteTitleFetchError.invalidURL
                }
                if target.url.scheme?.lowercased() == "https", redirectURL.scheme?.lowercased() == "http" {
                    throw WebsiteTitleFetchError.insecureRedirect
                }
                target = try LinkFetchSafety.validatedTarget(redirectURL.absoluteString, deadline: deadline)
                continue
            }
            if status == 401 || status == 403 { throw WebsiteTitleFetchError.authenticationRequired }
            guard (200...299).contains(status) else { throw WebsiteTitleFetchError.responseStatus(status) }
            let mime = received.response.mimeType?.lowercased() ?? ""
            guard mime == "text/html" || mime == "application/xhtml+xml" else {
                throw WebsiteTitleFetchError.nonHTML
            }
            if let title = WebsiteTitleParser.title(from: received.body, response: received.response) {
                return title
            }
            throw received.prefixLimitReached
                ? WebsiteTitleFetchError.bodyTooLarge
                : WebsiteTitleFetchError.noUsefulTitle
        }
    }
}
