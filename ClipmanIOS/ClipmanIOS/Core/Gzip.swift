import Foundation

enum GzipError: Error, LocalizedError, Equatable {
    case deflateInitFailed
    case inflateInitFailed
    case streamFailed(Int32)
    case compressedOutputTooLarge
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case .deflateInitFailed:
            "Could not initialize gzip compression."
        case .inflateInitFailed:
            "Could not initialize gzip decompression."
        case .streamFailed(let code):
            "Gzip stream failed with code \(code)."
        case .compressedOutputTooLarge:
            "The compressed data exceeds Clipman's configured safety limit."
        case .outputTooLarge:
            "The decompressed data exceeds Clipman's 256 MiB safety limit."
        }
    }
}
enum Gzip {
    static let maximumDecompressedBytes = 256 * 1024 * 1024

    struct PrefixResult: Sendable {
        let data: Data
        let reachedLimit: Bool
    }

    static func compress(_ data: Data, maximumOutputBytes: Int? = nil) throws -> Data {
        if let maximumOutputBytes, maximumOutputBytes < 0 {
            throw GzipError.compressedOutputTooLarge
        }
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
                let produced = buffer.count - Int(stream.avail_out)
                if let maximumOutputBytes,
                   produced > maximumOutputBytes - output.count {
                    throw GzipError.compressedOutputTooLarge
                }
                output.append(buffer, count: produced)
                if status == Z_STREAM_END { break }
            } while stream.avail_out == 0
            return output
        }
    }

    static func decompress(_ data: Data, maximumOutputBytes: Int = maximumDecompressedBytes) throws -> Data {
        let result = try decompressPrefix(data, maximumOutputBytes: maximumOutputBytes)
        guard !result.reachedLimit else { throw GzipError.outputTooLarge }
        return result.data
    }

    static func decompressPrefix(_ data: Data, maximumOutputBytes: Int) throws -> PrefixResult {
        guard maximumOutputBytes >= 0 else { throw GzipError.outputTooLarge }
        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else { throw GzipError.inflateInitFailed }
        defer { inflateEnd(&stream) }

        return try data.withUnsafeBytes { inputBuffer in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBuffer.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            repeat {
                let status = buffer.withUnsafeMutableBufferPointer { outputBuffer -> Int32 in
                    stream.next_out = outputBuffer.baseAddress
                    stream.avail_out = uInt(outputBuffer.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw GzipError.streamFailed(status) }
                let produced = buffer.count - Int(stream.avail_out)
                let remaining = maximumOutputBytes - output.count
                if produced > remaining {
                    output.append(buffer, count: remaining)
                    return PrefixResult(data: output, reachedLimit: true)
                }
                output.append(buffer, count: produced)
                if status == Z_STREAM_END { break }
                guard stream.avail_in > 0 || stream.avail_out == 0 else { throw GzipError.streamFailed(Z_BUF_ERROR) }
            } while true
            return PrefixResult(data: output, reachedLimit: false)
        }
    }
}
