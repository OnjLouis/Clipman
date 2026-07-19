import Foundation
import ClipmanCore

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

    init(serverURL: String, token: String, databasePassword: String) {
        let cleanedURL = ServerSettingsSanitizer.cleanTransportURL(serverURL)
        let cleanedToken = ServerSettingsSanitizer.cleanToken(token)
        self.baseURL = URL(string: cleanedURL)
        self.token = cleanedToken
        self.databaseID = ServerDatabaseIdentity.fromTokenAndPassword(token: cleanedToken, password: databasePassword)
        self.isConfigured = self.baseURL != nil && !cleanedToken.isEmpty
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
        request.setValue("ClipmanMac/2.0.3", forHTTPHeaderField: "User-Agent")
        if let expectedRevision, !expectedRevision.isEmpty {
            request.setValue(expectedRevision, forHTTPHeaderField: "If-Match")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }

        let semaphore = DispatchSemaphore(value: 0)
        let result = ServerRequestBox()
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result.set(.failure(error))
            } else {
                result.set(.success((data ?? Data(), response!)))
            }
            semaphore.signal()
        }.resume()
        if semaphore.wait(timeout: .now() + .seconds(10)) == .timedOut {
            throw ServerStorageError.timeout
        }

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
            "User-Agent: ClipmanMac/2.0.3",
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
        let responseData = try readAll(from: input)
        return try parseRawHTTPResponse(responseData, url: url)
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

    private func readAll(from input: InputStream) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = input.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else if count == 0 {
                break
            } else {
                throw input.streamError ?? ServerStorageError.invalidResponse("Socket read failed.")
            }
        }
        return data
    }

    private func parseRawHTTPResponse(_ responseData: Data, url: URL) throws -> (Data, HTTPURLResponse) {
        let marker = Data([13, 10, 13, 10])
        guard let headerRange = responseData.range(of: marker) else {
            throw ServerStorageError.invalidResponse("Missing response headers.")
        }
        let headerData = responseData[..<headerRange.lowerBound]
        let body = Data(responseData[headerRange.upperBound...])
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
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            throw ServerStorageError.invalidResponse("Could not create response object.")
        }
        switch status {
        case 200..<300:
            return (body, response)
        case 404:
            throw ServerStorageError.notFound
        case 409, 412:
            throw ServerStorageError.conflict
        default:
            let message = String(data: body, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: status)
            throw ServerStorageError.httpStatus(status, message)
        }
    }

    private func metadata(from response: HTTPURLResponse) -> ServerDatabaseMetadata {
        let revision = response.value(forHTTPHeaderField: "X-Clipman-Revision") ?? ""
        let length = Int64(response.value(forHTTPHeaderField: "Content-Length") ?? "") ?? -1
        return ServerDatabaseMetadata(revision: revision, length: length)
    }
}
