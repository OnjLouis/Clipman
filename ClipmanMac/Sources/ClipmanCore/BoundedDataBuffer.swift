import Foundation

package enum BoundedDataBufferError: Equatable, Error, Sendable {
    case invalidLimit
    case limitExceeded(Int)
}

package struct BoundedDataBuffer: Sendable {
    package let maximumBytes: Int
    package private(set) var data: Data

    package init(maximumBytes: Int) {
        precondition(maximumBytes >= 0)
        self.maximumBytes = maximumBytes
        self.data = Data()
    }

    package init(maximumBytes: Int, expectedBytes: Int64) throws {
        guard maximumBytes >= 0 else { throw BoundedDataBufferError.invalidLimit }
        if expectedBytes > Int64(maximumBytes) {
            throw BoundedDataBufferError.limitExceeded(maximumBytes)
        }

        self.maximumBytes = maximumBytes
        self.data = Data()
        if expectedBytes > 0 {
            data.reserveCapacity(min(Int(expectedBytes), 1024 * 1024))
        }
    }

    package mutating func append(_ bytes: Data) throws {
        guard bytes.count <= maximumBytes - data.count else {
            throw BoundedDataBufferError.limitExceeded(maximumBytes)
        }
        data.append(bytes)
    }

    package mutating func append(_ bytes: UnsafePointer<UInt8>, count: Int) throws {
        guard count >= 0, count <= maximumBytes - data.count else {
            throw BoundedDataBufferError.limitExceeded(maximumBytes)
        }
        data.append(bytes, count: count)
    }
}
