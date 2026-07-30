import Foundation
import Security

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
        case .httpStatus(let status, let message):
            "Clipman Server returned HTTP \(status): \(message)"
        case .requestFailed(let server, let message):
            "Could not reach Clipman Server at \(server): \(message)"
        }
    }
}

final class ServerStorageClient {
    let isConfigured: Bool
    private let baseURL: URL?
    private let token: String
    private let databaseID: String
    private let displayEndpoint: String
    private let session: URLSession
    private let sessionDelegate: ServerSessionDelegate
    private let userAgent = "ClipmanIOS/" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")

    init(settings: ClipmanSettings) {
        let displayURL = ServerSettingsSanitizer.cleanDisplayURL(settings.serverURL)
        let cleanedURL = ServerSettingsSanitizer.cleanTransportURL(settings.serverURL)
        let cleanedToken = ServerSettingsSanitizer.cleanToken(settings.serverToken)
        self.baseURL = URL(string: cleanedURL)
        self.token = cleanedToken
        self.databaseID = ServerDatabaseIdentity.fromTokenAndPassword(token: cleanedToken, password: settings.historyPassword)
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
            (data, response) = try await session.data(for: request)
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

private final class ServerSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let authority: ServerCertificateAuthority?

    init(authority: ServerCertificateAuthority?) {
        self.authority = authority
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
