import ClipmanCore
import Foundation
import Network
import Security

struct PinnedConnectionEndpoint: Sendable {
    let numericAddress: String
    let networkHost: NWEndpoint.Host

    init(validatedAddress: ValidatedNumericAddress) throws {
        numericAddress = validatedAddress.value
        if let address = IPv4Address(validatedAddress.value) {
            networkHost = .ipv4(address)
        } else if let address = IPv6Address(validatedAddress.value) {
            networkHost = .ipv6(address)
        } else {
            throw WebsiteTitleFetchError.cannotResolve
        }
    }
}

struct PinnedHTTPResponse: Sendable {
    let response: HTTPURLResponse
    let body: Data
    let prefixLimitReached: Bool
}

enum PinnedHTTPTransport {
    private static let maximumHeaderBytes = 64 * 1024
    private static let maximumWireBodyBytes = 512 * 1024

    static func get(target: ValidatedLinkTarget, deadline: MonotonicDeadline, maximumDecodedBodyBytes: Int) throws -> PinnedHTTPResponse {
        guard !target.numericAddresses.isEmpty else { throw WebsiteTitleFetchError.cannotResolve }
        var lastError: Error = WebsiteTitleFetchError.cannotResolve
        for validatedAddress in target.numericAddresses {
            guard !deadline.isExpired else { throw WebsiteTitleFetchError.timedOut }
            do {
                let endpoint = try PinnedConnectionEndpoint(validatedAddress: validatedAddress)
                let request = try requestData(for: target)
                let raw = try PinnedConnectionAttempt(
                    endpoint: endpoint,
                    originalHostname: target.originalHost,
                    port: target.port,
                    useTLS: target.url.scheme?.lowercased() == "https",
                    request: request,
                    maximumHeaderBytes: maximumHeaderBytes,
                    maximumWireBodyBytes: maximumWireBodyBytes,
                    maximumDecodedBodyBytes: maximumDecodedBodyBytes
                ).run(deadline: deadline)
                return try HTTPWireDecoder.decode(
                    raw,
                    url: target.url,
                    maximumDecodedBodyBytes: maximumDecodedBodyBytes,
                    maximumWireBodyBytes: maximumWireBodyBytes
                )
            } catch WebsiteTitleFetchError.timedOut {
                throw WebsiteTitleFetchError.timedOut
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func requestData(for target: ValidatedLinkTarget) throws -> Data {
        guard let components = URLComponents(url: target.url, resolvingAgainstBaseURL: false) else {
            throw WebsiteTitleFetchError.invalidURL
        }
        var requestTarget = components.percentEncodedPath
        if requestTarget.isEmpty { requestTarget = "/" }
        if let query = components.percentEncodedQuery, !query.isEmpty {
            requestTarget += "?\(query)"
        }
        let hostHeader = target.originalHost.contains(":") ? "[\(target.originalHost)]" : target.originalHost
        let request = [
            "GET \(requestTarget) HTTP/1.1",
            "Host: \(hostHeader)",
            "Accept: text/html,application/xhtml+xml",
            "Accept-Encoding: identity",
            "User-Agent: Clipman (+https://github.com/OnjLouis/Clipman; website title request)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        guard let data = request.data(using: .utf8) else { throw WebsiteTitleFetchError.invalidURL }
        return data
    }
}

private struct RawPinnedHTTPResponse: Sendable {
    let data: Data
    let stoppedAtLimit: Bool
}

private final class PinnedConnectionAttempt: @unchecked Sendable {
    private let endpoint: PinnedConnectionEndpoint
    private let originalHostname: String
    private let port: UInt16
    private let useTLS: Bool
    private let request: Data
    private let maximumHeaderBytes: Int
    private let maximumWireBodyBytes: Int
    private let maximumDecodedBodyBytes: Int
    private let queue = DispatchQueue(label: "me.onj.clipman.website-title-connection")
    private let completionSignal = DispatchSemaphore(value: 0)
    private var connection: NWConnection?
    private var received = Data()
    private var result: Result<RawPinnedHTTPResponse, Error>?
    private var finished = false

    init(
        endpoint: PinnedConnectionEndpoint,
        originalHostname: String,
        port: UInt16,
        useTLS: Bool,
        request: Data,
        maximumHeaderBytes: Int,
        maximumWireBodyBytes: Int,
        maximumDecodedBodyBytes: Int
    ) {
        self.endpoint = endpoint
        self.originalHostname = originalHostname
        self.port = port
        self.useTLS = useTLS
        self.request = request
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumWireBodyBytes = maximumWireBodyBytes
        self.maximumDecodedBodyBytes = maximumDecodedBodyBytes
    }

    func run(deadline: MonotonicDeadline) throws -> RawPinnedHTTPResponse {
        guard let networkPort = NWEndpoint.Port(rawValue: port) else {
            throw WebsiteTitleFetchError.invalidURL
        }
        let parameters: NWParameters
        if useTLS {
            let tls = NWProtocolTLS.Options()
            originalHostname.withCString {
                sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, $0)
            }
            "http/1.1".withCString {
                sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, $0)
            }
            sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            parameters = .tcp
        }

        let connection = NWConnection(host: endpoint.networkHost, port: networkPort, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendRequest()
            case .failed(let error):
                self.complete(.failure(WebsiteTitleFetchError.transport(error.localizedDescription)))
            case .cancelled:
                if !self.finished {
                    self.complete(.failure(WebsiteTitleFetchError.transport("The pinned website connection was cancelled.")))
                }
            default:
                break
            }
        }
        connection.start(queue: queue)

        if completionSignal.wait(timeout: deadline.dispatchTime) == .timedOut {
            queue.sync {
                if !finished {
                    finished = true
                    connection.stateUpdateHandler = nil
                    connection.forceCancel()
                }
            }
            throw WebsiteTitleFetchError.timedOut
        }
        guard let result else { throw WebsiteTitleFetchError.transport("The pinned website connection ended without a result.") }
        return try result.get()
    }

    private func sendRequest() {
        connection?.send(content: request, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.complete(.failure(WebsiteTitleFetchError.transport(error.localizedDescription)))
            } else {
                self.receiveNext()
            }
        })
    }

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let maximumWireBytes = maximumHeaderBytes + maximumWireBodyBytes
                let available = maximumWireBytes - received.count
                if available > 0 {
                    received.append(data.prefix(available))
                }
                if data.count > available {
                    complete(.success(RawPinnedHTTPResponse(data: received, stoppedAtLimit: true)))
                    return
                }
            }
            if let error {
                complete(.failure(WebsiteTitleFetchError.transport(error.localizedDescription)))
                return
            }
            do {
                switch try HTTPWireDecoder.progress(
                    received,
                    maximumHeaderBytes: maximumHeaderBytes,
                    maximumDecodedBodyBytes: maximumDecodedBodyBytes,
                    maximumWireBodyBytes: maximumWireBodyBytes
                ) {
                case .needMore:
                    if isComplete {
                        complete(.success(RawPinnedHTTPResponse(data: received, stoppedAtLimit: false)))
                    } else {
                        receiveNext()
                    }
                case .complete(let stoppedAtLimit):
                    complete(.success(RawPinnedHTTPResponse(data: received, stoppedAtLimit: stoppedAtLimit)))
                }
            } catch {
                complete(.failure(error))
            }
        }
    }

    private func complete(_ result: Result<RawPinnedHTTPResponse, Error>) {
        guard !finished else { return }
        finished = true
        self.result = result
        connection?.stateUpdateHandler = nil
        connection?.forceCancel()
        completionSignal.signal()
    }
}

private enum HTTPWireProgress {
    case needMore
    case complete(stoppedAtLimit: Bool)
}

private enum HTTPWireDecoder {
    private struct Header {
        let statusCode: Int
        let fields: [String: String]
        let bodyOffset: Int
    }

    static func progress(
        _ data: Data,
        maximumHeaderBytes: Int,
        maximumDecodedBodyBytes: Int,
        maximumWireBodyBytes: Int
    ) throws -> HTTPWireProgress {
        guard let header = try header(from: data, maximumHeaderBytes: maximumHeaderBytes) else { return .needMore }
        if (300...399).contains(header.statusCode) || !(200...299).contains(header.statusCode) {
            return .complete(stoppedAtLimit: false)
        }
        let body = data.dropFirst(header.bodyOffset)
        let encoding = contentEncoding(header.fields)
        try validateTransferEncoding(header.fields)
        let encodedBodyLimit = encoding == "gzip" || encoding == "x-gzip"
            ? maximumWireBodyBytes
            : maximumDecodedBodyBytes
        if isChunked(header.fields) {
            let chunks = try decodeChunked(body, maximumOutputBytes: encodedBodyLimit)
            if chunks.complete || chunks.reachedLimit {
                return .complete(stoppedAtLimit: chunks.reachedLimit)
            }
            return .needMore
        }
        if encoding == nil || encoding == "identity" {
            if body.count >= maximumDecodedBodyBytes {
                return .complete(stoppedAtLimit: contentLength(header.fields).map { $0 > maximumDecodedBodyBytes } ?? true)
            }
        } else if body.count >= maximumWireBodyBytes {
            return .complete(stoppedAtLimit: true)
        }
        if let length = contentLength(header.fields), body.count >= length {
            return .complete(stoppedAtLimit: false)
        }
        return .needMore
    }

    static func decode(
        _ raw: RawPinnedHTTPResponse,
        url: URL,
        maximumDecodedBodyBytes: Int,
        maximumWireBodyBytes: Int
    ) throws -> PinnedHTTPResponse {
        guard let header = try header(from: raw.data, maximumHeaderBytes: 64 * 1024) else {
            throw WebsiteTitleFetchError.transport("The website returned an incomplete HTTP response.")
        }
        var body = Data(raw.data.dropFirst(header.bodyOffset))
        var reachedLimit = raw.stoppedAtLimit
        let encoding = contentEncoding(header.fields)
        try validateTransferEncoding(header.fields)
        let encodedBodyLimit = encoding == "gzip" || encoding == "x-gzip"
            ? maximumWireBodyBytes
            : maximumDecodedBodyBytes
        if isChunked(header.fields) {
            let chunks = try decodeChunked(body, maximumOutputBytes: encodedBodyLimit)
            guard chunks.complete || chunks.reachedLimit else {
                throw WebsiteTitleFetchError.transport("The website returned an incomplete chunked response.")
            }
            body = chunks.data
            reachedLimit = reachedLimit || chunks.reachedLimit
        } else {
            if let length = contentLength(header.fields), body.count < min(length, encodedBodyLimit), !raw.stoppedAtLimit {
                throw WebsiteTitleFetchError.transport("The website returned an incomplete response body.")
            }
            if body.count > encodedBodyLimit {
                body = Data(body.prefix(encodedBodyLimit))
                reachedLimit = true
            } else if let length = contentLength(header.fields), length > encodedBodyLimit {
                reachedLimit = true
            }
        }

        if let encoding, encoding != "identity" {
            guard encoding == "gzip" || encoding == "x-gzip" else {
                throw WebsiteTitleFetchError.transport("The website returned an unsupported content encoding.")
            }
            let decompressed = try Gzip.decompressPrefix(body, maximumOutputBytes: maximumDecodedBodyBytes)
            body = decompressed.data
            reachedLimit = reachedLimit || decompressed.reachedLimit
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: header.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: header.fields
        ) else {
            throw WebsiteTitleFetchError.transport("The website returned invalid HTTP headers.")
        }
        return PinnedHTTPResponse(response: response, body: body, prefixLimitReached: reachedLimit)
    }

    private static func header(from data: Data, maximumHeaderBytes: Int) throws -> Header? {
        let delimiter = Data([13, 10, 13, 10])
        guard let range = data.range(of: delimiter) else {
            if data.count > maximumHeaderBytes {
                throw WebsiteTitleFetchError.transport("The website returned HTTP headers larger than 64 KiB.")
            }
            return nil
        }
        guard range.lowerBound <= maximumHeaderBytes,
              let text = String(data: data[..<range.lowerBound], encoding: .isoLatin1)
        else {
            throw WebsiteTitleFetchError.transport("The website returned invalid HTTP headers.")
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first,
              let match = statusLine.range(of: #"^HTTP/1\.[01] [0-9]{3}(?: |$)"#, options: .regularExpression),
              let statusCode = Int(statusLine[match].split(separator: " ")[1])
        else {
            throw WebsiteTitleFetchError.transport("The website returned an invalid HTTP status line.")
        }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard !line.first!.isWhitespace, let colon = line.firstIndex(of: ":") else {
                throw WebsiteTitleFetchError.transport("The website returned malformed HTTP headers.")
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw WebsiteTitleFetchError.transport("The website returned malformed HTTP headers.") }
            fields[name] = fields[name].map { "\($0), \(value)" } ?? value
        }
        return Header(statusCode: statusCode, fields: fields, bodyOffset: range.upperBound)
    }

    private static func contentLength(_ fields: [String: String]) -> Int? {
        guard let value = fields["content-length"], let length = Int(value), length >= 0 else { return nil }
        return length
    }

    private static func contentEncoding(_ fields: [String: String]) -> String? {
        fields["content-encoding"]?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isChunked(_ fields: [String: String]) -> Bool {
        fields["transfer-encoding"]?.lowercased().split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "chunked" } == true
    }

    private static func validateTransferEncoding(_ fields: [String: String]) throws {
        guard let value = fields["transfer-encoding"] else { return }
        let codings = value.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard codings == ["chunked"] else {
            throw WebsiteTitleFetchError.transport("The website returned an unsupported transfer encoding.")
        }
    }

    private struct ChunkResult {
        let data: Data
        let complete: Bool
        let reachedLimit: Bool
    }

    private static func decodeChunked(_ source: Data.SubSequence, maximumOutputBytes: Int) throws -> ChunkResult {
        let data = Data(source)
        let crlf = Data([13, 10])
        var cursor = 0
        var output = Data()
        while cursor < data.count {
            guard let lineRange = data.range(of: crlf, in: cursor..<data.count) else {
                return ChunkResult(data: output, complete: false, reachedLimit: false)
            }
            guard lineRange.lowerBound - cursor <= 1_024,
                  let line = String(data: data[cursor..<lineRange.lowerBound], encoding: .ascii)
            else {
                throw WebsiteTitleFetchError.transport("The website returned an invalid chunk size.")
            }
            let sizeText = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            guard let size = Int(sizeText, radix: 16), size >= 0 else {
                throw WebsiteTitleFetchError.transport("The website returned an invalid chunk size.")
            }
            cursor = lineRange.upperBound
            if size == 0 {
                return ChunkResult(data: output, complete: true, reachedLimit: false)
            }
            guard size <= 16 * 1024 * 1024 else {
                throw WebsiteTitleFetchError.bodyTooLarge
            }
            guard size <= data.count - cursor, data.count - cursor - size >= 2 else {
                return ChunkResult(data: output, complete: false, reachedLimit: false)
            }
            let remaining = maximumOutputBytes - output.count
            if size > remaining {
                output.append(data[cursor..<(cursor + remaining)])
                return ChunkResult(data: output, complete: false, reachedLimit: true)
            }
            output.append(data[cursor..<(cursor + size)])
            cursor += size
            guard data[cursor..<(cursor + 2)] == crlf else {
                throw WebsiteTitleFetchError.transport("The website returned malformed chunk framing.")
            }
            cursor += 2
        }
        return ChunkResult(data: output, complete: false, reachedLimit: false)
    }
}
