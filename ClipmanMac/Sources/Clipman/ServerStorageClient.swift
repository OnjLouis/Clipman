import Foundation
import ClipmanCore
import Network
import Security

private final class ServerRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<(Data, URLResponse), Error>?

    func set(_ result: Result<(Data, URLResponse), Error>) {
        lock.lock()
        value = result
        lock.unlock()
    }

    func get() throws -> (Data, URLResponse) {
        lock.lock()
        let result = value
        lock.unlock()
        return try result!.get()
    }
}

private let maximumServerDatabaseResponseBytes = ClipDatabaseFile.maximumStoredDatabaseBytes

struct ServerDatabaseMetadata: Equatable {
    var revision: String
    var length: Int64
}

struct ServerDatabaseDownload {
    var metadata: ServerDatabaseMetadata
    var data: Data
}

enum ServerStorageError: Error, LocalizedError {
    case notConfigured
    case notFound
    case conflict
    case timeout
    case invalidResponse(String)
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Clipman Server is not configured."
        case .notFound:
            "The Clipman Server database does not exist yet."
        case .conflict:
            "The Clipman Server database changed during upload."
        case .timeout:
            "Clipman Server did not respond before the request timed out."
        case .invalidResponse(let message):
            "Clipman Server returned an invalid response: \(message)"
        case .httpStatus(let status, let message):
            "Clipman Server returned HTTP \(status): \(message)"
        }
    }
}

final class ServerStorageClient: @unchecked Sendable {
    let isConfigured: Bool
    private let baseURL: URL?
    private let token: String
    private let databaseID: String
    private let certificateAuthority: ServerCertificateAuthority?
    private let userAgent = "ClipmanMac/" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")

    init(serverURL: String, token: String, databasePassword: String, caCertPEM: String = "", caHost: String = "") {
        let cleanedURL = ServerSettingsSanitizer.cleanTransportURL(serverURL)
        let cleanedToken = ServerSettingsSanitizer.cleanToken(token)
        self.baseURL = URL(string: cleanedURL)
        self.token = cleanedToken
        self.databaseID = ServerDatabaseIdentity.fromTokenAndPassword(token: cleanedToken, password: databasePassword)
        let authority = try? ServerSettingsSanitizer.parseCertificateAuthority(caCertPEM, address: serverURL)
        let normalizedAuthority = authority ?? nil
        let expectedHost = caHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let authorityMatches = normalizedAuthority == nil || expectedHost.isEmpty || normalizedAuthority?.host.caseInsensitiveCompare(expectedHost) == .orderedSame
        self.certificateAuthority = normalizedAuthority
        self.isConfigured = self.baseURL != nil && !cleanedToken.isEmpty && !databasePassword.isEmpty && authorityMatches && (caCertPEM.isEmpty || normalizedAuthority != nil)
    }

    func metadata() throws -> ServerDatabaseMetadata {
        let (_, response) = try request(method: "HEAD", body: nil, expectedRevision: nil)
        return metadata(from: response)
    }

    func download() throws -> ServerDatabaseDownload {
        let (data, response) = try request(method: "GET", body: nil, expectedRevision: nil)
        return ServerDatabaseDownload(metadata: metadata(from: response), data: data)
    }

    func upload(data: Data, expectedRevision: String) throws -> ServerDatabaseMetadata {
        let (_, response) = try request(method: "PUT", body: data, expectedRevision: expectedRevision)
        return metadata(from: response)
    }

    private func request(method: String, body: Data?, expectedRevision: String?) throws -> (Data, HTTPURLResponse) {
        guard let baseURL, isConfigured else { throw ServerStorageError.notConfigured }
        let url = baseURL.appendingPathComponent("api/v1/database/\(databaseID)")
        if url.scheme?.caseInsensitiveCompare("http") == .orderedSame {
            return try privateNetworkRequest(url: url, method: method, body: body, expectedRevision: expectedRevision)
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = method
        request.timeoutInterval = 8
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let expectedRevision, !expectedRevision.isEmpty {
            request.setValue(expectedRevision, forHTTPHeaderField: "If-Match")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }

        let semaphore = DispatchSemaphore(value: 0)
        let result = ServerRequestBox()
        let delegate = ServerSessionDelegate(
            authority: certificateAuthority,
            result: result,
            semaphore: semaphore
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        task.resume()
        if semaphore.wait(timeout: .now() + .seconds(10)) == .timedOut {
            task.cancel()
            session.invalidateAndCancel()
            throw ServerStorageError.timeout
        }
        session.finishTasksAndInvalidate()

        let (data, response) = try result.get()
        guard let http = response as? HTTPURLResponse else {
            throw ServerStorageError.httpStatus(0, "No HTTP response.")
        }
        switch http.statusCode {
        case 200..<300:
            return (data, http)
        case 404:
            throw ServerStorageError.notFound
        case 409, 412:
            throw ServerStorageError.conflict
        default:
            let message = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw ServerStorageError.httpStatus(http.statusCode, message)
        }
    }

    private func privateNetworkRequest(
        url: URL,
        method: String,
        body: Data?,
        expectedRevision: String?
    ) throws -> (Data, HTTPURLResponse) {
        let portValue = url.port ?? 80
        guard let host = url.host,
              (1...65_535).contains(portValue),
              let port = NWEndpoint.Port(rawValue: UInt16(portValue))
        else { throw ServerStorageError.notConfigured }

        let hostHeader = host.contains(":") ? "[\(host)]" : host
        var requestTarget = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            requestTarget += "?\(query)"
        }
        let bodyData = body ?? Data()
        var headers = [
            "\(method) \(requestTarget) HTTP/1.1",
            "Host: \(hostHeader):\(port.rawValue)",
            "Authorization: Bearer \(token)",
            "User-Agent: \(userAgent)",
            "Accept-Encoding: identity",
            "Connection: close"
        ]
        if let expectedRevision, !expectedRevision.isEmpty {
            headers.append("If-Match: \(expectedRevision)")
        }
        if body != nil {
            headers.append("Content-Type: application/octet-stream")
        }
        headers.append("Content-Length: \(bodyData.count)")
        guard var requestData = (headers.joined(separator: "\r\n") + "\r\n\r\n").data(using: .utf8) else {
            throw ServerStorageError.invalidResponse("Could not encode request.")
        }
        requestData.append(bodyData)

        let attempt = ServerHTTPConnectionAttempt(
            host: NWEndpoint.Host(host),
            port: port,
            request: requestData,
            responseURL: url,
            expectsBody: method.caseInsensitiveCompare("HEAD") != .orderedSame
        )
        let (data, response) = try attempt.run(timeoutSeconds: 10)
        switch response.statusCode {
        case 200..<300:
            return (data, response)
        case 404:
            throw ServerStorageError.notFound
        case 409, 412:
            throw ServerStorageError.conflict
        default:
            let message = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw ServerStorageError.httpStatus(response.statusCode, message)
        }
    }

    private func databaseResponseTooLargeError() -> ServerStorageError {
        ServerStorageError.invalidResponse("Database response exceeded the 272 MiB client compatibility limit.")
    }

    private func metadata(from response: HTTPURLResponse) -> ServerDatabaseMetadata {
        let revision = response.value(forHTTPHeaderField: "X-Clipman-Revision") ?? ""
        let length = Int64(response.value(forHTTPHeaderField: "Content-Length") ?? "") ?? -1
        return ServerDatabaseMetadata(revision: revision, length: length)
    }
}

private final class ServerHTTPConnectionAttempt: @unchecked Sendable {
    private static let maximumHeaderBytes = 64 * 1024

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let request: Data
    private let responseURL: URL
    private let expectsBody: Bool
    private let queue = DispatchQueue(label: "Clipman.ServerHTTPConnection")
    private let completionSignal = DispatchSemaphore(value: 0)
    private var connection: NWConnection?
    private var pendingHeaders = Data()
    private var response: HTTPURLResponse?
    private var expectedBodyBytes: Int64 = -1
    private var body = BoundedDataBuffer(maximumBytes: maximumServerDatabaseResponseBytes)
    private var result: Result<(Data, HTTPURLResponse), Error>?
    private var finished = false

    init(
        host: NWEndpoint.Host,
        port: NWEndpoint.Port,
        request: Data,
        responseURL: URL,
        expectsBody: Bool
    ) {
        self.host = host
        self.port = port
        self.request = request
        self.responseURL = responseURL
        self.expectsBody = expectsBody
    }

    func run(timeoutSeconds: TimeInterval) throws -> (Data, HTTPURLResponse) {
        let connection = NWConnection(host: host, port: port, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendRequest()
            case .failed(let error):
                self.complete(.failure(error))
            case .cancelled:
                if !self.finished {
                    self.complete(.failure(ServerStorageError.invalidResponse("The private server connection was cancelled.")))
                }
            default:
                break
            }
        }
        connection.start(queue: queue)

        if completionSignal.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            queue.sync {
                guard !finished else { return }
                finished = true
                connection.stateUpdateHandler = nil
                connection.forceCancel()
            }
            throw ServerStorageError.timeout
        }
        guard let result else {
            throw ServerStorageError.invalidResponse("The private server connection ended without a result.")
        }
        return try result.get()
    }

    private func sendRequest() {
        connection?.send(content: request, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.complete(.failure(error))
            } else {
                self.receiveNext()
            }
        })
    }

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.complete(.failure(error))
                return
            }
            do {
                if let data, !data.isEmpty {
                    try self.consume(data)
                }
                if self.finished { return }
                if isComplete {
                    try self.finishAtEndOfStream()
                } else {
                    self.receiveNext()
                }
            } catch {
                self.complete(.failure(error))
            }
        }
    }

    private func consume(_ data: Data) throws {
        guard response == nil else {
            try appendBody(data)
            return
        }

        pendingHeaders.append(data)
        let marker = Data([13, 10, 13, 10])
        guard let headerRange = pendingHeaders.range(of: marker) else {
            guard pendingHeaders.count <= Self.maximumHeaderBytes else {
                throw ServerStorageError.invalidResponse("Response headers exceeded the 64 KiB limit.")
            }
            return
        }
        guard headerRange.lowerBound <= Self.maximumHeaderBytes else {
            throw ServerStorageError.invalidResponse("Response headers exceeded the 64 KiB limit.")
        }

        let parsed = try parseHeaders(Data(pendingHeaders[..<headerRange.lowerBound]))
        response = parsed.response
        expectedBodyBytes = parsed.contentLength
        body = try BoundedDataBuffer(
            maximumBytes: maximumServerDatabaseResponseBytes,
            expectedBytes: expectedBodyBytes
        )
        let remaining = Data(pendingHeaders[headerRange.upperBound...])
        pendingHeaders.removeAll(keepingCapacity: false)

        if !expectsBody {
            complete(.success((Data(), parsed.response)))
            return
        }
        try appendBody(remaining)
    }

    private func appendBody(_ data: Data) throws {
        guard !data.isEmpty else { return }
        if expectedBodyBytes >= 0,
           Int64(body.data.count) + Int64(data.count) > expectedBodyBytes {
            throw ServerStorageError.invalidResponse("Response body exceeded Content-Length.")
        }
        do {
            try body.append(data)
        } catch BoundedDataBufferError.limitExceeded {
            throw responseTooLargeError()
        }
        if expectedBodyBytes >= 0, Int64(body.data.count) == expectedBodyBytes,
           let response {
            complete(.success((body.data, response)))
        }
    }

    private func finishAtEndOfStream() throws {
        guard let response else {
            throw ServerStorageError.invalidResponse("Missing response headers.")
        }
        if expectedBodyBytes >= 0, Int64(body.data.count) != expectedBodyBytes {
            throw ServerStorageError.invalidResponse("Response body length did not match Content-Length.")
        }
        complete(.success((body.data, response)))
    }

    private func parseHeaders(_ data: Data) throws -> (response: HTTPURLResponse, contentLength: Int64) {
        guard let text = String(data: data, encoding: .isoLatin1) else {
            throw ServerStorageError.invalidResponse("Response headers were not readable.")
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw ServerStorageError.invalidResponse("Missing status line.")
        }
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw ServerStorageError.invalidResponse("Unreadable status line.")
        }
        var fields: [String: String] = [:]
        var contentLength: Int64 = -1
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            fields[name] = value
            if name.caseInsensitiveCompare("Content-Length") == .orderedSame {
                guard let length = Int64(value), length >= 0 else {
                    throw ServerStorageError.invalidResponse("Content-Length was not a valid byte count.")
                }
                contentLength = length
            }
        }
        if contentLength > Int64(maximumServerDatabaseResponseBytes) {
            throw responseTooLargeError()
        }
        guard let response = HTTPURLResponse(
            url: responseURL,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: fields
        ) else {
            throw ServerStorageError.invalidResponse("Could not create response object.")
        }
        return (response, contentLength)
    }

    private func complete(_ result: Result<(Data, HTTPURLResponse), Error>) {
        guard !finished else { return }
        finished = true
        self.result = result
        connection?.stateUpdateHandler = nil
        connection?.forceCancel()
        completionSignal.signal()
    }

    private func responseTooLargeError() -> ServerStorageError {
        ServerStorageError.invalidResponse("Database response exceeded the 272 MiB client compatibility limit.")
    }
}

private final class ServerSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
    private let authority: ServerCertificateAuthority?
    private let result: ServerRequestBox
    private let semaphore: DispatchSemaphore
    private let lock = NSLock()
    private var response: URLResponse?
    private var buffer = BoundedDataBuffer(maximumBytes: maximumServerDatabaseResponseBytes)
    private var completed = false

    init(authority: ServerCertificateAuthority?, result: ServerRequestBox, semaphore: DispatchSemaphore) {
        self.authority = authority
        self.result = result
        self.semaphore = semaphore
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let authority,
              challenge.protectionSpace.host.caseInsensitiveCompare(authority.host) == .orderedSame,
              let trust = challenge.protectionSpace.serverTrust,
              let anchor = SecCertificateCreateWithData(nil, authority.der as CFData)
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let root = chain.last,
              SecCertificateCopyData(root) as Data == authority.der
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            let freshBuffer = try BoundedDataBuffer(
                maximumBytes: maximumServerDatabaseResponseBytes,
                expectedBytes: response.expectedContentLength
            )
            lock.lock()
            self.response = response
            buffer = freshBuffer
            lock.unlock()
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            finish(.failure(responseTooLargeError()))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        do {
            try buffer.append(data)
            lock.unlock()
        } catch {
            lock.unlock()
            dataTask.cancel()
            finish(.failure(responseTooLargeError()))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
            return
        }
        lock.lock()
        let response = self.response
        let data = buffer.data
        lock.unlock()
        guard let response else {
            finish(.failure(ServerStorageError.invalidResponse("No HTTP response.")))
            return
        }
        finish(.success((data, response)))
    }

    private func finish(_ requestResult: Result<(Data, URLResponse), Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        result.set(requestResult)
        semaphore.signal()
    }

    private func responseTooLargeError() -> ServerStorageError {
        ServerStorageError.invalidResponse("Database response exceeded the 272 MiB client compatibility limit.")
    }
}
