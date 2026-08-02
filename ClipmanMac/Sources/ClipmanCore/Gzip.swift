import Foundation
import CZlib

public enum GzipError: Error, LocalizedError, Equatable {
    case deflateInitFailed
    case inflateInitFailed
    case outputLimitExceeded(Int)
    case streamFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .deflateInitFailed: "Could not initialize gzip compression."
        case .inflateInitFailed: "Could not initialize gzip decompression."
        case .outputLimitExceeded(let limit): "Gzip decompression exceeded the \(limit)-byte safety limit."
        case .streamFailed(let code): "Gzip stream failed with code \(code)."
        }
    }
}

public enum Gzip {
    public static let maximumDecompressedBytes = 256 * 1024 * 1024

    public struct PrefixResult: Sendable {
        public let data: Data
        public let reachedLimit: Bool
    }

    public static func compress(_ data: Data) throws -> Data {
        var stream = z_stream()
        let initStatus = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else { throw GzipError.deflateInitFailed }
        defer { deflateEnd(&stream) }

        return try data.withUnsafeBytes { inputBuffer in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBuffer.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            repeat {
                let status = buffer.withUnsafeMutableBufferPointer { outputBuffer -> Int32 in
                    stream.next_out = outputBuffer.baseAddress
                    stream.avail_out = uInt(outputBuffer.count)
                    return deflate(&stream, Z_FINISH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw GzipError.streamFailed(status) }
                output.append(buffer, count: buffer.count - Int(stream.avail_out))
                if status == Z_STREAM_END { break }
            } while stream.avail_out == 0
            return output
        }
    }

    public static func decompress(_ data: Data, maximumOutputBytes: Int = maximumDecompressedBytes) throws -> Data {
        let result = try inflateBounded(data, maximumOutputBytes: maximumOutputBytes)
        guard !result.reachedLimit else { throw GzipError.outputLimitExceeded(maximumOutputBytes) }
        return result.data
    }

    public static func decompressPrefix(_ data: Data, maximumOutputBytes: Int) throws -> PrefixResult {
        try inflateBounded(data, maximumOutputBytes: maximumOutputBytes)
    }

    private static func inflateBounded(_ data: Data, maximumOutputBytes: Int) throws -> PrefixResult {
        guard maximumOutputBytes >= 0 else { throw GzipError.outputLimitExceeded(maximumOutputBytes) }
        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else { throw GzipError.inflateInitFailed }
        defer { inflateEnd(&stream) }

        return try data.withUnsafeBytes { inputBuffer in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBuffer.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            while stream.avail_in > 0 {
                let remaining = maximumOutputBytes - output.count
                let requested = min(buffer.count, remaining + 1)
                let status = buffer.withUnsafeMutableBufferPointer { outputBuffer -> Int32 in
                    stream.next_out = outputBuffer.baseAddress
                    stream.avail_out = uInt(requested)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw GzipError.streamFailed(status) }
                let produced = requested - Int(stream.avail_out)
                if produced > remaining {
                    output.append(buffer, count: remaining)
                    return PrefixResult(data: output, reachedLimit: true)
                }
                output.append(buffer, count: produced)
                if status == Z_STREAM_END { break }
            }
            return PrefixResult(data: output, reachedLimit: false)
        }
    }
}
