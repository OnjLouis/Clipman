import Foundation
import Security

protocol ServerStorageSettingsProviding {
    var serverURL: String { get }
    var serverToken: String { get }
    var serverCaCertPEM: String { get }
    var serverCaHost: String { get }
    var historyPassword: String { get }
}

struct ServerDatabaseDownload {
    var revision: String
    var data: Data
}

struct ServerDatabaseMetadata {
    var revision: String
}

enum ServerStorageError: Error, LocalizedError {
    case notConfigured
    case notFound
    case conflict
    case responseTooLarge
    case httpStatus(Int, String)
    case requestFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Clipman Server is not configured."
        case .notFound:
            "The Clipman Server database does not exist yet."
        case .conflict:
            "Clipman Server reported a revision conflict."
        case .responseTooLarge:
            "The Clipman database transfer exceeds Clipman's 272 MiB container safety limit."
        case .httpStatus(let status, let message):
            "Clipman Server returned HTTP \(status): \(message)"
        case .requestFailed(let server, let message):
            "Could not reach Clipman Server at \(server): \(message)"
        }
    }
}

final class ServerStorageClient {
    let isConfigured: Bool
    let syncCacheIdentity: String
    private let baseURL: URL?
    private let token: String
    private let databaseID: String
    private let displayEndpoint: String
    private let maximumResponseBytes: Int
    private let session: URLSession
    private let sessionDelegate: ServerSessionDelegate
    private let userAgent = "ClipmanIOS/" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")

    init(
        settings: some ServerStorageSettingsProviding,
        maximumResponseBytes: Int = ClipDatabaseFile.maximumFileBytes
    ) {
        let displayURL = ServerSettingsSanitizer.cleanDisplayURL(settings.serverURL)
        let cleanedURL = ServerSettingsSanitizer.cleanTransportURL(settings.serverURL)
        let cleanedToken = ServerSettingsSanitizer.cleanToken(settings.serverToken)
        self.baseURL = URL(string: cleanedURL)
        self.token = cleanedToken
        self.databaseID = ServerDatabaseIdentity.fromTokenAndPassword(token: cleanedToken, password: settings.historyPassword)
        self.syncCacheIdentity = cleanedURL + "|" + self.databaseID
        self.maximumResponseBytes = max(0, min(maximumResponseBytes, ClipDatabaseFile.maximumFileBytes))
        let authority = try? ServerSettingsSanitizer.parseCertificateAuthority(settings.serverCaCertPEM, address: settings.serverURL)
        let normalizedAuthority = authority ?? nil
        let authorityMatches = normalizedAuthority == nil || settings.serverCaHost.isEmpty || normalizedAuthority?.host.caseInsensitiveCompare(settings.serverCaHost) == .orderedSame
        self.sessionDelegate = ServerSessionDelegate(authority: normalizedAuthority)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: configuration, delegate: sessionDelegate, delegateQueue: nil)
        if let url = URL(string: displayURL) {
            let host = url.host ?? "unknown host"
            let port = url.port.map { ":\($0)" } ?? ""
            self.displayEndpoint = "\(url.scheme ?? "unknown")://\(host)\(port)"
        } else {
            self.displayEndpoint = "invalid server address"
        }
        self.isConfigured = self.baseURL != nil && !cleanedToken.isEmpty && !settings.historyPassword.isEmpty && authorityMatches && (settings.serverCaCertPEM.isEmpty || normalizedAuthority != nil)
    }

    func metadata() async throws -> ServerDatabaseMetadata {
        let (_, response) = try await request(method: "HEAD", body: nil, expectedRevision: nil)
        return metadata(from: response)
    }

    func download() async throws -> ServerDatabaseDownload {
        let (data, response) = try await request(method: "GET", body: nil, expectedRevision: nil)
        return ServerDatabaseDownload(revision: metadata(from: response).revision, data: data)
    }

    func upload(data: Data, expectedRevision: String) async throws -> String {
        guard data.count <= ClipDatabaseFile.maximumFileBytes else {
            throw ServerStorageError.responseTooLarge
        }
        let (_, response) = try await request(method: "PUT", body: data, expectedRevision: expectedRevision)
        return metadata(from: response).revision
    }

    private func request(method: String, body: Data?, expectedRevision: String?) async throws -> (Data, HTTPURLResponse) {
        guard let baseURL, isConfigured else { throw ServerStorageError.notConfigured }
        let url = baseURL.appendingPathComponent("api/v1/database/\(databaseID)")
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 8
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let expectedRevision, !expectedRevision.isEmpty {
            request.setValue(expectedRevision, forHTTPHeaderField: "If-Match")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await sessionDelegate.data(
                for: request,
                using: session,
                maximumBytes: maximumResponseBytes
            )
        } catch BoundedResponseError.responseTooLarge {
            throw ServerStorageError.responseTooLarge
        } catch {
            throw ServerStorageError.requestFailed(displayEndpoint, friendlyNetworkMessage(for: error))
        }
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

    private func cleanRevision(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\" \r\n\t"))
    }

    private func metadata(from response: HTTPURLResponse) -> ServerDatabaseMetadata {
        ServerDatabaseMetadata(
            revision: cleanRevision(response.value(forHTTPHeaderField: "X-Clipman-Revision") ?? response.value(forHTTPHeaderField: "ETag"))
        )
    }

    private func friendlyNetworkMessage(for error: Error) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorCancelled:
            return "The request was cancelled."
        case NSURLErrorTimedOut:
            return "The request timed out."
        case NSURLErrorCannotFindHost:
            return "The server name could not be found."
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet:
            return "The server is not reachable."
        default:
            return error.localizedDescription
        }
    }
}

enum BoundedResponseError: Error, Equatable {
    case responseTooLarge
}

struct BoundedResponseBuffer {
    let maximumBytes: Int
    private(set) var data = Data()

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    static func accepts(expectedContentLength: Int64, maximumBytes: Int) -> Bool {
        guard maximumBytes >= 0 else { return false }
        return expectedContentLength < 0 || UInt64(expectedContentLength) <= UInt64(maximumBytes)
    }

    mutating func append(_ chunk: Data) throws {
        guard maximumBytes >= 0,
              data.count <= maximumBytes,
              chunk.count <= maximumBytes - data.count else {
            throw BoundedResponseError.responseTooLarge
        }
        data.append(chunk)
    }
}

private final class BoundedDataTaskState: @unchecked Sendable {
    var buffer: BoundedResponseBuffer
    var response: URLResponse?
    let continuation: CheckedContinuation<(Data, URLResponse), Error>

    init(maximumBytes: Int, continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        self.buffer = BoundedResponseBuffer(maximumBytes: maximumBytes)
        self.continuation = continuation
    }
}

private final class ServerSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let authority: ServerCertificateAuthority?
    private let stateLock = NSLock()
    private var dataTaskStates: [Int: BoundedDataTaskState] = [:]

    init(authority: ServerCertificateAuthority?) {
        self.authority = authority
    }

    func data(
        for request: URLRequest,
        using session: URLSession,
        maximumBytes: Int
    ) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request)
            let state = BoundedDataTaskState(maximumBytes: maximumBytes, continuation: continuation)
            stateLock.lock()
            dataTaskStates[task.taskIdentifier] = state
            stateLock.unlock()
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        var rejectedState: BoundedDataTaskState?
        stateLock.lock()
        if let state = dataTaskStates[dataTask.taskIdentifier] {
            if BoundedResponseBuffer.accepts(
                expectedContentLength: response.expectedContentLength,
                maximumBytes: state.buffer.maximumBytes
            ) {
                state.response = response
            } else {
                rejectedState = dataTaskStates.removeValue(forKey: dataTask.taskIdentifier)
            }
        }
        stateLock.unlock()

        guard let rejectedState else {
            completionHandler(.allow)
            return
        }
        completionHandler(.cancel)
        dataTask.cancel()
        rejectedState.continuation.resume(throwing: BoundedResponseError.responseTooLarge)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var rejectedState: BoundedDataTaskState?
        stateLock.lock()
        if let state = dataTaskStates[dataTask.taskIdentifier] {
            do {
                try state.buffer.append(data)
            } catch {
                rejectedState = dataTaskStates.removeValue(forKey: dataTask.taskIdentifier)
            }
        }
        stateLock.unlock()

        if let rejectedState {
            dataTask.cancel()
            rejectedState.continuation.resume(throwing: BoundedResponseError.responseTooLarge)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stateLock.lock()
        let state = dataTaskStates.removeValue(forKey: task.taskIdentifier)
        stateLock.unlock()
        guard let state else { return }
        if let error {
            state.continuation.resume(throwing: error)
        } else if let response = state.response {
            state.continuation.resume(returning: (state.buffer.data, response))
        } else {
            state.continuation.resume(throwing: URLError(.badServerResponse))
        }
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
}
