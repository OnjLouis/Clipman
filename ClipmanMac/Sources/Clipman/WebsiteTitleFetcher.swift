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
        case .capabilityURL: return "This link contains a token-like path or a credential-related parameter, so Clipman will not contact it."
        case .cannotResolve: return "The website address could not be resolved to a validated public destination."
        case .redirectLimit: return "The website redirected more than three times."
        case .insecureRedirect: return "The website tried to redirect from HTTPS to insecure HTTP."
        case .authenticationRequired: return "The website requires authentication, so Clipman did not use its title."
        case .responseStatus(let status): return "The website returned HTTP status \(status)."
        case .nonHTML: return "The link did not return an HTML page."
        case .bodyTooLarge: return "The website did not provide a useful title within Clipman's bounded reading limits."
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
        let decodedPath = components.percentEncodedPath.removingPercentEncoding ?? components.percentEncodedPath
        if decodedPath.split(separator: "/").contains(where: { isOpaqueToken(String($0)) }) { return true }

        let sensitiveQueryNames = [
            "access_token", "apikey", "api_key", "auth", "authorization", "challenge", "code", "confirmation", "credential", "hmac",
            "id_token", "invite", "jwt", "key", "nonce", "one_time", "otp", "passcode", "password", "reset",
            "secret", "session", "sig", "signature", "signed", "sso", "state", "ticket", "token", "verification",
            "awsaccesskeyid", "googleaccessid", "key-pair-id"
        ]
        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
            if sensitiveQueryNames.contains(where: {
                name == $0 || name.hasSuffix("_\($0)") || name.hasSuffix("-\($0)") || name.hasSuffix(".\($0)")
            }) {
                return true
            }
            if name.hasPrefix("x-amz-") || name.hasPrefix("x-goog-") { return true }
        }
        return false
    }

    private static func isOpaqueToken(_ value: String) -> Bool {
        let compact = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count >= 32, !compact.contains(where: \.isWhitespace) else { return false }
        if compact.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) != nil {
            return true
        }
        let pageSuffixes = [".html", ".htm", ".shtml"]
        let lowercased = compact.lowercased()
        let slug = pageSuffixes.first(where: { lowercased.hasSuffix($0) })
            .map { String(compact.dropLast($0.count)) } ?? compact
        let parts = slug.split(whereSeparator: { $0 == "-" || $0 == "_" })
        let readableWords = parts.filter { part in
            part.count >= 3 && part.count <= 24 && part.allSatisfy(\.isLetter)
        }
        let readableParts = parts.allSatisfy { part in
            let articleDigits = part.first?.isLetter == true ? part.dropFirst() : part[...]
            let isArticleID = articleDigits.count >= 4 && articleDigits.count <= 12 && articleDigits.allSatisfy(\.isNumber)
            return part.count <= 24 && (part.allSatisfy(\.isLetter) || isArticleID)
        }
        if parts.count >= 5, readableParts, readableWords.count >= 4 {
            return false
        }
        return compact.filter(\.isLetter).count >= 8 && compact.filter(\.isNumber).count >= 4
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

final class WebsiteTitleFetcher: @unchecked Sendable {
    private static let maxBodyBytes = 2 * 1024 * 1024

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
            if let title = WebsiteMetadataParser.title(from: received.body, response: received.response, host: target.originalHost) {
                return title
            }
            throw received.prefixLimitReached
                ? WebsiteTitleFetchError.bodyTooLarge
                : WebsiteTitleFetchError.noUsefulTitle
        }
    }
}
