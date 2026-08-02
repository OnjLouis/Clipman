import Foundation
import ClipmanCore
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
            return try rawHTTPRequestWithTimeout(url: url, method: method, body: body, expectedRevision: expectedRevision)
        }
        var request = URLRequest(url: url)
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

    private func rawHTTPRequestWithTimeout(url: URL, method: String, body: Data?, expectedRevision: String?) throws -> (Data, HTTPURLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        let result = ServerRequestBox()
        DispatchQueue.global(qos: .utility).async {
            do {
                let response = try self.rawHTTPRequest(url: url, method: method, body: body, expectedRevision: expectedRevision)
                result.set(.success(response))
            } catch {
                result.set(.failure(error))
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + .seconds(10)) == .timedOut {
            throw ServerStorageError.timeout
        }
        let (data, response) = try result.get()
        guard let http = response as? HTTPURLResponse else {
            throw ServerStorageError.httpStatus(0, "No HTTP response.")
        }
        return (data, http)
    }

    private func rawHTTPRequest(url: URL, method: String, body: Data?, expectedRevision: String?) throws -> (Data, HTTPURLResponse) {
        guard let host = url.host else { throw ServerStorageError.notConfigured }
        let port = url.port ?? 80
        let path = url.path.isEmpty ? "/" : url.path
        let bodyData = body ?? Data()

        var headerLines = [
            "\(method) \(path) HTTP/1.1",
            "Host: \(host):\(port)",
            "Authorization: Bearer \(token)",
            "User-Agent: \(userAgent)",
            "Connection: close"
        ]
        if let expectedRevision, !expectedRevision.isEmpty {
            headerLines.append("If-Match: \(expectedRevision)")
        }
        if body != nil {
            headerLines.append("Content-Type: application/octet-stream")
            headerLines.append("Content-Length: \(bodyData.count)")
        } else {
            headerLines.append("Content-Length: 0")
        }
        let header = headerLines.joined(separator: "\r\n") + "\r\n\r\n"
        guard var requestData = header.data(using: .utf8) else {
            throw ServerStorageError.invalidResponse("Could not encode request.")
        }
        requestData.append(bodyData)

        var readStream: InputStream?
        var writeStream: OutputStream?
        Stream.getStreamsToHost(withName: host, port: port, inputStream: &readStream, outputStream: &writeStream)
        guard let input = readStream, let output = writeStream else {
            throw ServerStorageError.invalidResponse("Could not open connection.")
        }
        input.open()
        output.open()
        defer {
            input.close()
            output.close()
        }

        try writeAll(requestData, to: output)
        return try readRawHTTPResponse(
            from: input,
            url: url,
            expectsBody: ServerHTTPResponsePolicy.expectsBody(forMethod: method)
        )
    }

    private func writeAll(_ data: Data, to output: OutputStream) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = output.write(base.advanced(by: offset), maxLength: data.count - offset)
                if written < 0 {
                    throw output.streamError ?? ServerStorageError.invalidResponse("Socket write failed.")
                }
                if written == 0 {
                    Thread.sleep(forTimeInterval: 0.01)
                    continue
                }
                offset += written
            }
        }
    }

    private func readRawHTTPResponse(
        from input: InputStream,
        url: URL,
        expectsBody: Bool
    ) throws -> (Data, HTTPURLResponse) {
        let marker = Data([13, 10, 13, 10])
        let maximumHeaderBytes = 64 * 1024
        var pendingHeaders = Data()
        var response: HTTPURLResponse?
        var expectedBodyBytes: Int64 = -1
        var body = BoundedDataBuffer(maximumBytes: maximumServerDatabaseResponseBytes)
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = input.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                let chunk = Data(buffer.prefix(count))
                if response == nil {
                    pendingHeaders.append(chunk)
                    if let headerRange = pendingHeaders.range(of: marker) {
                        guard headerRange.lowerBound <= maximumHeaderBytes else {
                            throw ServerStorageError.invalidResponse("Response headers exceeded the 64 KiB limit.")
                        }
                        let parsed = try parseRawHTTPHeaders(
                            Data(pendingHeaders[..<headerRange.lowerBound]),
                            url: url
                        )
                        if !expectsBody {
                            return try validateRawHTTPStatus(Data(), response: parsed.response)
                        }
                        response = parsed.response
                        expectedBodyBytes = parsed.contentLength
                        do {
                            body = try BoundedDataBuffer(
                                maximumBytes: maximumServerDatabaseResponseBytes,
                                expectedBytes: expectedBodyBytes
                            )
                            try body.append(Data(pendingHeaders[headerRange.upperBound...]))
                        } catch BoundedDataBufferError.limitExceeded {
                            throw databaseResponseTooLargeError()
                        }
                        pendingHeaders.removeAll(keepingCapacity: false)
                    } else if pendingHeaders.count > maximumHeaderBytes {
                        throw ServerStorageError.invalidResponse("Response headers exceeded the 64 KiB limit.")
                    }
                } else {
                    do {
                        try body.append(chunk)
                    } catch BoundedDataBufferError.limitExceeded {
                        throw databaseResponseTooLargeError()
                    }
                }
            } else if count == 0 {
                break
            } else {
                throw input.streamError ?? ServerStorageError.invalidResponse("Socket read failed.")
            }
        }
        guard let response else {
            throw ServerStorageError.invalidResponse("Missing response headers.")
        }
        if expectedBodyBytes >= 0, Int64(body.data.count) != expectedBodyBytes {
            throw ServerStorageError.invalidResponse("Response body length did not match Content-Length.")
        }
        return try validateRawHTTPStatus(body.data, response: response)
    }

    private func parseRawHTTPHeaders(_ headerData: Data, url: URL) throws -> (response: HTTPURLResponse, contentLength: Int64) {
        guard let headerText = String(data: headerData, encoding: .isoLatin1) else {
            throw ServerStorageError.invalidResponse("Response headers were not readable.")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw ServerStorageError.invalidResponse("Missing status line.")
        }
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw ServerStorageError.invalidResponse("Unreadable status line.")
        }
        var headers: [String: String] = [:]
        var contentLength: Int64 = -1
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
            if name.caseInsensitiveCompare("Content-Length") == .orderedSame {
                guard let parsedLength = Int64(value), parsedLength >= 0 else {
                    throw ServerStorageError.invalidResponse("Content-Length was not a valid byte count.")
                }
                contentLength = parsedLength
            }
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            throw ServerStorageError.invalidResponse("Could not create response object.")
        }
        if contentLength > Int64(maximumServerDatabaseResponseBytes) {
            throw databaseResponseTooLargeError()
        }
        return (response, contentLength)
    }

    private func validateRawHTTPStatus(_ body: Data, response: HTTPURLResponse) throws -> (Data, HTTPURLResponse) {
        switch response.statusCode {
        case 200..<300:
            return (body, response)
        case 404:
            throw ServerStorageError.notFound
        case 409, 412:
            throw ServerStorageError.conflict
        default:
            let message = String(data: body, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
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
