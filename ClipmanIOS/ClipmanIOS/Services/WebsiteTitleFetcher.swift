import Darwin
import Foundation
import Network
import Security

enum WebsiteTitleError: LocalizedError, Equatable {
    case unsupportedURL
    case unsafeURL(String)
    case unavailable
    case nonHTML
    case responseTooLarge
    case missingTitle

    var errorDescription: String? {
        switch self {
        case .unsupportedURL:
            return "Website titles are available only for public HTTP or HTTPS links using the standard port."
        case .unsafeURL(let reason):
            return "Clipman did not contact this link because it may be private or sensitive: \(reason)"
        case .unavailable:
            return "The website title could not be retrieved."
        case .nonHTML:
            return "The link did not return an HTML page."
        case .responseTooLarge:
            return "The page did not provide a useful title within Clipman's bounded reading limits."
        case .missingTitle:
            return "The page did not provide a usable website title."
        }
    }
}

enum WebsiteTitlePolicy {
    private static let blockedQueryNames: Set<String> = [
        "access_token", "apikey", "api_key", "auth", "authorization", "challenge", "code", "confirmation", "credential", "hmac", "id_token",
        "invite", "jwt", "key", "nonce", "one_time", "otp", "passcode", "password", "reset", "secret", "session", "sig",
        "signature", "signed", "sso", "state", "ticket", "token", "verification", "awsaccesskeyid", "googleaccessid", "key-pair-id"
    ]

    static func validate(_ url: URL) throws {
        let host = try validateStructure(url)
        _ = try PublicNetworkAddressResolver.resolve(host: host)
    }

    @discardableResult
    static func validateStructure(_ url: URL) throws -> String {
        guard LinkPresentationSafety.isWithinURLLimit(url.absoluteString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            throw WebsiteTitleError.unsupportedURL
        }
        guard components.user == nil, components.password == nil else {
            throw WebsiteTitleError.unsafeURL("the address contains sign-in information")
        }
        if let port = components.port,
           !((scheme == "http" && port == 80) || (scheme == "https" && port == 443)) {
            throw WebsiteTitleError.unsupportedURL
        }
        let pathSegments = components.percentEncodedPath.split(separator: "/").map {
            (String($0).removingPercentEncoding ?? String($0)).lowercased()
        }
        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
            if isBlockedQueryName(name) {
                throw WebsiteTitleError.unsafeURL("the address contains a credential-like parameter")
            }
        }
        for segment in pathSegments where looksLikeSecret(segment) {
            throw WebsiteTitleError.unsafeURL("the address contains a token-like path")
        }
        try PublicNetworkAddressResolver.validateHostName(host)
        return host
    }

    private static func looksLikeSecret(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 32, !trimmed.contains(where: \.isWhitespace) else { return false }
        if trimmed.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) != nil {
            return true
        }
        let pageSuffixes = [".html", ".htm", ".shtml"]
        let lowercased = trimmed.lowercased()
        let slug = pageSuffixes.first(where: { lowercased.hasSuffix($0) })
            .map { String(trimmed.dropLast($0.count)) } ?? trimmed
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
        return trimmed.filter(\.isLetter).count >= 8 && trimmed.filter(\.isNumber).count >= 4
    }

    private static func isBlockedQueryName(_ name: String) -> Bool {
        if blockedQueryNames.contains(name) { return true }
        if name.hasPrefix("x-amz-") || name.hasPrefix("x-goog-") { return true }
        return blockedQueryNames.contains {
            name.hasSuffix("_\($0)") || name.hasSuffix("-\($0)") || name.hasSuffix(".\($0)")
        }
    }
}

struct WebsiteTitleResolvedAddress: Equatable, Hashable, Sendable {
    let text: String
    let family: Int32
}

enum PublicNetworkAddressResolver {
    static func validateHostName(_ host: String) throws {
        let lower = host.lowercased()
        if lower == "localhost" || lower.hasSuffix(".localhost") || lower.hasSuffix(".local") ||
            lower.hasSuffix(".internal") || lower.hasSuffix(".lan") || lower.hasSuffix(".home") {
            throw WebsiteTitleError.unsafeURL("the host is local")
        }
    }

    static func resolve(host: String) throws -> [WebsiteTitleResolvedAddress] {
        try validateHostName(host)

        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            throw WebsiteTitleError.unavailable
        }
        defer { freeaddrinfo(first) }

        var addresses: [WebsiteTitleResolvedAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ai_next }
            guard let address = current.pointee.ai_addr else { continue }
            switch Int32(current.pointee.ai_family) {
            case AF_INET:
                let result = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                    (UInt32(bigEndian: pointer.pointee.sin_addr.s_addr), numericIPv4(pointer.pointee.sin_addr))
                }
                guard isPublicIPv4(result.0), let text = result.1 else {
                    throw WebsiteTitleError.unsafeURL("the host resolves to a private or reserved address")
                }
                addresses.append(WebsiteTitleResolvedAddress(text: text, family: AF_INET))
            case AF_INET6:
                let result = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                    (withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }, numericIPv6(pointer.pointee.sin6_addr))
                }
                guard isPublicIPv6(result.0), let text = result.1 else {
                    throw WebsiteTitleError.unsafeURL("the host resolves to a private or reserved address")
                }
                addresses.append(WebsiteTitleResolvedAddress(text: text, family: AF_INET6))
            default:
                break
            }
        }
        let unique = Array(Set(addresses)).sorted {
            if $0.family != $1.family { return $0.family == AF_INET6 }
            return $0.text < $1.text
        }
        guard !unique.isEmpty else { throw WebsiteTitleError.unavailable }
        return Array(unique.prefix(16))
    }

    private static func numericIPv4(_ address: in_addr) -> String? {
        var value = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &value, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return decodedAddress(buffer)
    }

    private static func numericIPv6(_ address: in6_addr) -> String? {
        var value = address
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &value, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return decodedAddress(buffer)
    }

    private static func decodedAddress(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func isPublicIPv4(_ value: UInt32) -> Bool {
        let a = UInt8((value >> 24) & 0xff)
        let b = UInt8((value >> 16) & 0xff)
        let c = UInt8((value >> 8) & 0xff)
        if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
        if a == 100 && (64...127).contains(b) { return false }
        if a == 169 && b == 254 { return false }
        if a == 172 && (16...31).contains(b) { return false }
        if a == 192 && b == 168 { return false }
        if a == 192 && b == 0 { return false }
        if a == 192 && b == 31 && c == 196 { return false }
        if a == 192 && b == 52 && c == 193 { return false }
        if a == 192 && b == 88 && c == 99 { return false }
        if a == 192 && b == 175 && c == 48 { return false }
        if a == 198 && (b == 18 || b == 19) { return false }
        if a == 198 && b == 51 && c == 100 { return false }
        if a == 203 && b == 0 && c == 113 { return false }
        return true
    }

    static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            let ipv4 = bytes[12...15].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return isPublicIPv4(ipv4)
        }
        if bytes.prefix(12).elementsEqual([0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0]) {
            let ipv4 = bytes[12...15].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return isPublicIPv4(ipv4)
        }
        if bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xff && bytes[3] == 0x9b && bytes[4] == 0x00 && bytes[5] == 0x01 {
            return false
        }
        guard (bytes[0] & 0xe0) == 0x20 else { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] <= 0x01 { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8 { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x02 { return false }
        if bytes[0] == 0x3f && bytes[1] == 0xff && (bytes[2] & 0xf0) == 0x00 { return false }
        if bytes[0] == 0x26 && bytes[1] == 0x20 && bytes[2] == 0x00 && bytes[3] == 0x4f &&
            bytes[4] == 0x80 && bytes[5] == 0x00 { return false }
        let ipv4Tail = bytes[12...15].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        if isSensitiveIPv4Tail(ipv4Tail) { return false }
        return true
    }

    private static func isSensitiveIPv4Tail(_ value: UInt32) -> Bool {
        let a = UInt8((value >> 24) & 0xff)
        let b = UInt8((value >> 16) & 0xff)
        if a == 10 || a == 127 { return true }
        if a == 100 && (64...127).contains(b) { return true }
        if a == 169 && b == 254 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 192 && b == 168 { return true }
        return false
    }
}

enum WebsiteTitleRedirectPolicy {
    static func rejectsDowngrade(from source: URL?, to destination: URL) -> Bool {
        source?.scheme?.lowercased() == "https" && destination.scheme?.lowercased() != "https"
    }
}

struct WebsiteTitleConnectionPlan: Equatable, Sendable {
    let numericAddress: String
    let addressFamily: Int32
    let originalHost: String
    let port: UInt16
    let usesTLS: Bool

    init(url: URL, address: WebsiteTitleResolvedAddress) throws {
        guard LinkPresentationSafety.isWithinURLLimit(url.absoluteString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host else {
            throw WebsiteTitleError.unsupportedURL
        }
        numericAddress = address.text
        addressFamily = address.family
        originalHost = host
        usesTLS = scheme == "https"
        guard let safePort = UInt16(exactly: components.port ?? (usesTLS ? 443 : 80)) else {
            throw WebsiteTitleError.unsupportedURL
        }
        port = safePort
    }
}

enum WebsiteTitleRequestBuilder {
    static func request(for url: URL) throws -> Data {
        guard LinkPresentationSafety.isWithinURLLimit(url.absoluteString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host else {
            throw WebsiteTitleError.unsupportedURL
        }
        var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery, !query.isEmpty { target += "?\(query)" }
        let hostValue = host.contains(":") ? "[\(host)]" : host
        let request = [
            "GET \(target) HTTP/1.1",
            "Host: \(hostValue)",
            "Accept: text/html,application/xhtml+xml;q=0.9",
            "Accept-Encoding: gzip",
            "User-Agent: Clipman/WebsiteTitle",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        guard let data = request.data(using: .utf8) else { throw WebsiteTitleError.unavailable }
        return data
    }
}

struct WebsiteTitleWireResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
    let bodyWasTruncated: Bool
}

private enum WebsiteTitleParseResult {
    case needMore
    case response(WebsiteTitleWireResponse)
}

private enum WebsiteTitleHTTPParser {
    static let maximumHeaderBytes = 32 * 1024
    static let maximumWireBodyBytes = 1024 * 1024
    static let maximumDecodedBodyBytes = 2 * 1024 * 1024
    static let maximumWireBytes = maximumHeaderBytes + maximumWireBodyBytes + 4
    private static let headerTerminator = Data([13, 10, 13, 10])
    private static let lineTerminator = Data([13, 10])

    static func parse(_ data: Data, reachedEOF: Bool) throws -> WebsiteTitleParseResult {
        guard let headerRange = data.range(of: headerTerminator) else {
            if data.count > maximumHeaderBytes || reachedEOF { throw WebsiteTitleError.unavailable }
            return .needMore
        }
        guard headerRange.lowerBound <= maximumHeaderBytes,
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .isoLatin1) else {
            throw WebsiteTitleError.unavailable
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw WebsiteTitleError.unavailable }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/1."), let status = Int(statusParts[1]) else {
            throw WebsiteTitleError.unavailable
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { throw WebsiteTitleError.unavailable }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw WebsiteTitleError.unavailable }
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        if (300...399).contains(status) || !(200...299).contains(status) {
            return .response(WebsiteTitleWireResponse(statusCode: status, headers: headers, body: Data(), bodyWasTruncated: false))
        }
        let body = Data(data[headerRange.upperBound...])
        if let transfer = headers["transfer-encoding"]?.lowercased(), transfer != "identity" {
            guard transfer.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) == ["chunked"] else {
                throw WebsiteTitleError.unavailable
            }
            switch try decodeChunked(body, reachedEOF: reachedEOF) {
            case .needMore:
                return .needMore
            case .response(let decoded):
                return .response(try decodedResponse(
                    statusCode: status,
                    headers: headers,
                    encodedBody: decoded.body,
                    wireWasTruncated: decoded.bodyWasTruncated
                ))
            }
        }
        if let rawLength = headers["content-length"] {
            guard !rawLength.contains(","), let length = Int(rawLength), length >= 0 else {
                throw WebsiteTitleError.unavailable
            }
            if body.count >= min(length, maximumWireBodyBytes + 1) {
                let truncated = length > maximumWireBodyBytes
                return .response(try decodedResponse(
                    statusCode: status,
                    headers: headers,
                    encodedBody: Data(body.prefix(maximumWireBodyBytes)),
                    wireWasTruncated: truncated
                ))
            }
            if reachedEOF { throw WebsiteTitleError.unavailable }
            return .needMore
        }
        if body.count > maximumWireBodyBytes {
            return .response(try decodedResponse(
                statusCode: status,
                headers: headers,
                encodedBody: Data(body.prefix(maximumWireBodyBytes)),
                wireWasTruncated: true
            ))
        }
        if reachedEOF {
            return .response(try decodedResponse(statusCode: status, headers: headers, encodedBody: body, wireWasTruncated: false))
        }
        return .needMore
    }

    private static func decodeChunked(_ data: Data, reachedEOF: Bool) throws -> WebsiteTitleParseResult {
        var cursor = data.startIndex
        var output = Data()
        output.reserveCapacity(maximumWireBodyBytes)
        while true {
            guard let lineRange = data.range(of: lineTerminator, in: cursor..<data.endIndex) else {
                if reachedEOF { throw WebsiteTitleError.unavailable }
                return .needMore
            }
            guard lineRange.lowerBound - cursor <= 32,
                  let line = String(data: data[cursor..<lineRange.lowerBound], encoding: .ascii),
                  let sizeToken = line.split(separator: ";", maxSplits: 1).first,
                  let chunkSize = Int(sizeToken.trimmingCharacters(in: .whitespaces), radix: 16),
                  chunkSize >= 0 else {
                throw WebsiteTitleError.unavailable
            }
            cursor = lineRange.upperBound
            if chunkSize == 0 {
                return .response(WebsiteTitleWireResponse(statusCode: 200, headers: [:], body: output, bodyWasTruncated: false))
            }
            let available = data.endIndex - cursor
            let bytesNeededForLimit = maximumWireBodyBytes + 1 - output.count
            if chunkSize > available {
                if available >= bytesNeededForLimit {
                    output.append(data[cursor..<(cursor + bytesNeededForLimit)])
                    return .response(WebsiteTitleWireResponse(statusCode: 200, headers: [:], body: Data(output.prefix(maximumWireBodyBytes)), bodyWasTruncated: true))
                }
                if reachedEOF { throw WebsiteTitleError.unavailable }
                return .needMore
            }
            output.append(data[cursor..<(cursor + min(chunkSize, bytesNeededForLimit))])
            if output.count > maximumWireBodyBytes {
                return .response(WebsiteTitleWireResponse(statusCode: 200, headers: [:], body: Data(output.prefix(maximumWireBodyBytes)), bodyWasTruncated: true))
            }
            cursor += chunkSize
            guard data.distance(from: cursor, to: data.endIndex) >= 2 else {
                if reachedEOF { throw WebsiteTitleError.unavailable }
                return .needMore
            }
            guard data[cursor] == 13, data[data.index(after: cursor)] == 10 else { throw WebsiteTitleError.unavailable }
            cursor += 2
        }
    }

    private static func decodedResponse(
        statusCode: Int,
        headers: [String: String],
        encodedBody: Data,
        wireWasTruncated: Bool
    ) throws -> WebsiteTitleWireResponse {
        let encoding = headers["content-encoding"]?.lowercased().trimmingCharacters(in: .whitespaces) ?? "identity"
        if encoding.isEmpty || encoding == "identity" {
            let truncated = wireWasTruncated || encodedBody.count > maximumDecodedBodyBytes
            return WebsiteTitleWireResponse(
                statusCode: statusCode,
                headers: headers,
                body: Data(encodedBody.prefix(maximumDecodedBodyBytes)),
                bodyWasTruncated: truncated
            )
        }
        guard encoding == "gzip" || encoding == "x-gzip" else { throw WebsiteTitleError.nonHTML }
        let decompressed = try Gzip.decompressPrefix(encodedBody, maximumOutputBytes: maximumDecodedBodyBytes)
        return WebsiteTitleWireResponse(
            statusCode: statusCode,
            headers: headers,
            body: decompressed.data,
            bodyWasTruncated: wireWasTruncated || decompressed.reachedLimit
        )
    }
}

private enum WebsiteTitleTransportError: Error {
    case connectionFailed
}

private final class WebsiteTitlePinnedConnection: @unchecked Sendable {
    private let plan: WebsiteTitleConnectionPlan
    private let request: Data
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "me.onj.clipman.website-title-connection")
    private let completion: @Sendable (Result<WebsiteTitleWireResponse, Error>) -> Void
    private var connection: NWConnection?
    private var received = Data()
    private var finished = false

    init(
        plan: WebsiteTitleConnectionPlan,
        request: Data,
        timeout: TimeInterval,
        completion: @escaping @Sendable (Result<WebsiteTitleWireResponse, Error>) -> Void
    ) {
        self.plan = plan
        self.request = request
        self.timeout = timeout
        self.completion = completion
    }

    func start() {
        queue.async { self.startOnQueue() }
    }

    private func startOnQueue() {
        guard let host = endpointHost(), let port = NWEndpoint.Port(rawValue: plan.port) else {
            finish(.failure(WebsiteTitleTransportError.connectionFailed))
            return
        }
        let parameters: NWParameters
        if plan.usesTLS {
            let tls = NWProtocolTLS.Options()
            plan.originalHost.withCString {
                sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, $0)
            }
            "http/1.1".withCString {
                sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, $0)
            }
            let originalHost = plan.originalHost
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, protocolTrust, complete in
                let trust = sec_trust_copy_ref(protocolTrust).takeRetainedValue()
                let policy = SecPolicyCreateSSL(true, originalHost as CFString)
                let policyStatus = SecTrustSetPolicies(trust, policy)
                complete(policyStatus == errSecSuccess && SecTrustEvaluateWithError(trust, nil))
            }, queue)
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            parameters = .tcp
        }
        let connection = NWConnection(host: host, port: port, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { state in self.handle(state) }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) {
            self.finish(.failure(WebsiteTitleTransportError.connectionFailed))
        }
    }

    private func endpointHost() -> NWEndpoint.Host? {
        if plan.addressFamily == AF_INET, let address = IPv4Address(plan.numericAddress) { return .ipv4(address) }
        if plan.addressFamily == AF_INET6, let address = IPv6Address(plan.numericAddress) { return .ipv6(address) }
        return nil
    }

    private func handle(_ state: NWConnection.State) {
        guard !finished else { return }
        switch state {
        case .ready:
            connection?.send(content: request, completion: .contentProcessed { error in
                self.queue.async {
                    if error == nil { self.receive() }
                    else { self.finish(.failure(WebsiteTitleTransportError.connectionFailed)) }
                }
            })
        case .failed:
            finish(.failure(WebsiteTitleTransportError.connectionFailed))
        case .cancelled:
            finish(.failure(WebsiteTitleTransportError.connectionFailed))
        default:
            break
        }
    }

    private func receive() {
        guard !finished else { return }
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { data, _, complete, error in
            self.queue.async {
                guard !self.finished else { return }
                if let data { self.received.append(data) }
                guard self.received.count <= WebsiteTitleHTTPParser.maximumWireBytes else {
                    self.finish(.failure(WebsiteTitleError.responseTooLarge))
                    return
                }
                if error != nil {
                    self.finish(.failure(WebsiteTitleTransportError.connectionFailed))
                    return
                }
                do {
                    switch try WebsiteTitleHTTPParser.parse(self.received, reachedEOF: complete) {
                    case .needMore:
                        if complete { self.finish(.failure(WebsiteTitleError.unavailable)) }
                        else { self.receive() }
                    case .response(let response):
                        self.finish(.success(response))
                    }
                } catch {
                    self.finish(.failure(error))
                }
            }
        }
    }

    private func finish(_ result: Result<WebsiteTitleWireResponse, Error>) {
        guard !finished else { return }
        finished = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        completion(result)
    }
}

private final class WebsiteTitleResolutionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[WebsiteTitleResolvedAddress], Error>?

    init(_ continuation: CheckedContinuation<[WebsiteTitleResolvedAddress], Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<[WebsiteTitleResolvedAddress], Error>) {
        let current: CheckedContinuation<[WebsiteTitleResolvedAddress], Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        current?.resume(with: result)
    }
}

enum WebsiteTitleFetcher {
    private static let totalTimeout: TimeInterval = 8
    typealias AddressResolver = @Sendable (String) async throws -> [WebsiteTitleResolvedAddress]
    typealias ResponseFetcher = @Sendable (URL, [WebsiteTitleResolvedAddress], Data) async throws -> WebsiteTitleWireResponse

    static func fetchTitle(for url: URL) async throws -> String {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(totalTimeout * 1_000_000_000)
        return try await fetchTitle(
            for: url,
            resolveAddresses: { try await resolve(host: $0, deadline: deadline) },
            fetchResponse: { try await fetch($0, addresses: $1, request: $2, deadline: deadline) }
        )
    }

    static func fetchTitle(
        for url: URL,
        resolveAddresses: @escaping AddressResolver,
        fetchResponse: @escaping ResponseFetcher
    ) async throws -> String {
        var currentURL = url
        var redirectCount = 0
        while true {
            let host = try WebsiteTitlePolicy.validateStructure(currentURL)
            let addresses = try await resolveAddresses(host)
            let request = try WebsiteTitleRequestBuilder.request(for: currentURL)
            let response = try await fetchResponse(currentURL, addresses, request)

            if (300...399).contains(response.statusCode) {
                guard redirectCount < 3,
                      let location = response.headers["location"],
                      LinkPresentationSafety.isWithinURLLimit(location),
                      let destination = URL(string: location, relativeTo: currentURL)?.absoluteURL else {
                    throw WebsiteTitleError.unsafeURL("the page redirected more than three times or provided an invalid address")
                }
                if WebsiteTitleRedirectPolicy.rejectsDowngrade(from: currentURL, to: destination) {
                    throw WebsiteTitleError.unsafeURL("the page redirected from HTTPS to an insecure address")
                }
                redirectCount += 1
                currentURL = destination
                continue
            }

            guard (200...299).contains(response.statusCode) else { throw WebsiteTitleError.unavailable }
            let mimeType = response.headers["content-type"]?.split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard mimeType == "text/html" || mimeType == "application/xhtml+xml" else {
                throw WebsiteTitleError.nonHTML
            }
            guard let source = String(data: response.body, encoding: .utf8)
                    ?? String(data: response.body, encoding: .isoLatin1) else {
                throw response.bodyWasTruncated ? WebsiteTitleError.responseTooLarge : WebsiteTitleError.missingTitle
            }
            if let title = WebsiteTitleParser.title(from: source, host: host) { return title }
            throw response.bodyWasTruncated ? WebsiteTitleError.responseTooLarge : WebsiteTitleError.missingTitle
        }
    }

    private static func resolve(host: String, deadline: UInt64) async throws -> [WebsiteTitleResolvedAddress] {
        let remaining = try remainingTime(until: deadline)
        return try await withCheckedThrowingContinuation { continuation in
            let gate = WebsiteTitleResolutionGate(continuation)
            DispatchQueue.global(qos: .utility).async {
                gate.finish(Result { try PublicNetworkAddressResolver.resolve(host: host) })
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + remaining) {
                gate.finish(.failure(WebsiteTitleError.unavailable))
            }
        }
    }

    private static func fetch(
        _ url: URL,
        addresses: [WebsiteTitleResolvedAddress],
        request: Data,
        deadline: UInt64
    ) async throws -> WebsiteTitleWireResponse {
        var lastConnectionError: Error = WebsiteTitleError.unavailable
        for address in addresses {
            let remaining = try remainingTime(until: deadline)
            let attemptTimeout = min(2.5, remaining)
            let plan = try WebsiteTitleConnectionPlan(url: url, address: address)
            do {
                return try await withCheckedThrowingContinuation { continuation in
                    WebsiteTitlePinnedConnection(plan: plan, request: request, timeout: attemptTimeout) {
                        continuation.resume(with: $0)
                    }.start()
                }
            } catch WebsiteTitleTransportError.connectionFailed {
                lastConnectionError = WebsiteTitleError.unavailable
            }
        }
        throw lastConnectionError
    }

    private static func remainingTime(until deadline: UInt64) throws -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline > now else { throw WebsiteTitleError.unavailable }
        return TimeInterval(deadline - now) / 1_000_000_000
    }
}

enum WebsiteTitleParser {
    private static let maximumMetadataCharacters = 128 * 1024
    private static let nonMetadataElements = ["script", "style", "template", "noscript", "svg", "iframe"]
    private static let exactJunkTitles = Set([
        "just a moment", "attention required", "access denied", "access to this page has been denied",
        "are you a robot", "are you a human", "please wait", "javascript is disabled",
        "javascript is required", "enable javascript", "security check", "checking your browser",
        "verify you are human", "human verification", "bot verification", "one moment please", "loading",
        "redirecting", "error", "page not found", "not found", "404", "403 forbidden", "forbidden",
        "site maintenance", "under construction", "untitled", "untitled document", "log in", "login",
        "sign in", "signin", "log in or sign up", "robot check", "captcha", "request blocked", "blocked",
        "reddit - dive into anything"
    ])
    private static let junkTitleFragments = [
        "please wait for verification", "checking if the site connection is secure",
        "enable javascript and cookies to continue", "verify you are a human",
        "your request has been blocked", "unusual traffic"
    ]

    static func title(from html: String, host: String = "") -> String? {
        let metadata = retainedMetadata(from: html)
        var openGraph: String?
        var twitter: String?
        if let regex = try? NSRegularExpression(pattern: #"<meta\b[^>]{0,4096}>"#, options: .caseInsensitive) {
            for match in regex.matches(in: metadata, range: NSRange(metadata.startIndex..<metadata.endIndex, in: metadata)) {
                guard let range = Range(match.range, in: metadata) else { continue }
                let attributes = parsedAttributes(String(metadata[range]))
                let key = (attributes["property"] ?? attributes["name"] ?? attributes["itemprop"] ?? "").lowercased()
                guard let content = attributes["content"], !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                if key == "og:title", openGraph == nil { openGraph = content }
                if key == "twitter:title", twitter == nil { twitter = content }
            }
        }
        let documentTitle = firstCapture(#"<title\b[^>]{0,1024}>(.*?)</title\s*>"#, in: metadata)
        let heading = firstCapture(#"<h1\b[^>]{0,4096}>(.*?)</h1\s*>"#, in: metadata)
        for candidate in [openGraph, twitter, documentTitle, heading] {
            guard let candidate,
                  let cleaned = sanitized(candidate.replacingOccurrences(of: "<[^>]{0,4096}>", with: " ", options: .regularExpression)),
                  !isJunkTitle(cleaned),
                  host.isEmpty || cleaned.caseInsensitiveCompare(host) != .orderedSame
            else { continue }
            return cleaned
        }
        return nil
    }

    private static func retainedMetadata(from html: String) -> String {
        let source = html as NSString
        let output = NSMutableString()
        var index = 0
        while index < source.length, output.length < maximumMetadataCharacters {
            if source.length - index >= 4, source.substring(with: NSRange(location: index, length: 4)) == "<!--" {
                let end = source.range(
                    of: "-->",
                    options: [],
                    range: NSRange(location: index + 4, length: source.length - index - 4)
                )
                index = end.location == NSNotFound ? source.length : NSMaxRange(end)
                continue
            }
            if source.character(at: index) != 60 {
                let next = source.range(
                    of: "<",
                    options: [],
                    range: NSRange(location: index, length: source.length - index)
                )
                let end = next.location == NSNotFound ? source.length : next.location
                append(source, range: NSRange(location: index, length: end - index), to: output)
                index = end
                continue
            }
            guard let tagEnd = findTagEnd(source, start: index) else { break }
            let tagRange = NSRange(location: index, length: tagEnd - index + 1)
            let tag = source.substring(with: tagRange)
            let parsed = parsedTagName(tag)
            if !parsed.closing,
               nonMetadataElements.contains(parsed.name),
               !tag.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/>") {
                let close = source.range(
                    of: "</\(parsed.name)",
                    options: .caseInsensitive,
                    range: NSRange(location: tagEnd + 1, length: source.length - tagEnd - 1)
                )
                if close.location == NSNotFound { break }
                guard let closeEnd = findTagEnd(source, start: close.location) else { break }
                index = closeEnd + 1
                continue
            }
            append(source, range: tagRange, to: output)
            index = tagEnd + 1
        }
        return output as String
    }

    private static func append(_ source: NSString, range: NSRange, to output: NSMutableString) {
        let remaining = maximumMetadataCharacters - output.length
        guard remaining > 0, range.length > 0 else { return }
        output.append(source.substring(with: NSRange(location: range.location, length: min(range.length, remaining))))
    }

    private static func findTagEnd(_ source: NSString, start: Int) -> Int? {
        var quote: unichar = 0
        guard start + 1 < source.length else { return nil }
        for index in (start + 1)..<source.length {
            let character = source.character(at: index)
            if quote != 0 {
                if character == quote { quote = 0 }
            } else if character == 34 || character == 39 {
                quote = character
            } else if character == 62 {
                return index
            }
        }
        return nil
    }

    private static func parsedTagName(_ tag: String) -> (name: String, closing: Bool) {
        var value = tag.dropFirst().drop(while: \.isWhitespace)
        let closing = value.first == "/"
        if closing { value = value.dropFirst().drop(while: \.isWhitespace) }
        return (value.prefix { $0.isLetter || $0.isNumber || $0 == ":" || $0 == "-" }.lowercased(), closing)
    }

    private static func parsedAttributes(_ tag: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s\"'=<>`]+))"#
        ) else { return [:] }
        var result: [String: String] = [:]
        for match in regex.matches(in: tag, range: NSRange(tag.startIndex..<tag.endIndex, in: tag)) {
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

    private static func firstCapture(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    private static func sanitized(_ raw: String) -> String? {
        let decoded = HTMLEntityDecoder.decode(raw)
        let separators = CharacterSet(charactersIn: " |-\u{2013}\u{2014}\u{00B7}\u{00BB}<")
        let value = LinkPresentationSafety.cleanedText(decoded, maximumScalars: 200)
            .trimmingCharacters(in: separators)
        return value.isEmpty ? nil : value
    }

    private static func isJunkTitle(_ title: String) -> Bool {
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!|-\u{2013}\u{2014}"))
        let normalized = title.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: trim)
        return exactJunkTitles.contains(normalized) || junkTitleFragments.contains { normalized.contains($0) }
    }
}

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
        guard let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-f]+|[0-9]+);", options: [.caseInsensitive]) else {
            return output
        }
        for match in regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).reversed() {
            guard let whole = Range(match.range(at: 0), in: output),
                  let numberRange = Range(match.range(at: 1), in: output) else { continue }
            let token = String(output[numberRange])
            let radix = token.lowercased().hasPrefix("x") ? 16 : 10
            let digits = radix == 16 ? String(token.dropFirst()) : token
            guard let scalarValue = UInt32(digits, radix: radix),
                  let scalar = UnicodeScalar(scalarValue) else { continue }
            output.replaceSubrange(whole, with: String(scalar))
        }
        return output
    }
}
