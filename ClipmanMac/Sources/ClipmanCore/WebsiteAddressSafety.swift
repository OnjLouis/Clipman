import Darwin
import Foundation

package enum WebsiteAddressSafety {
    package static func allowsLiteralAddress(_ host: String) -> Bool {
        guard let bytes = parseLiteralAddress(host) else { return false }
        return isGlobalAddress(bytes)
    }

    package static func parseLiteralAddress(_ host: String) -> [UInt8]? {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            return withUnsafeBytes(of: &ipv4) { Array($0) }
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            return withUnsafeBytes(of: &ipv6) { Array($0) }
        }
        return nil
    }

    package static func canonicalNumericAddress(_ host: String) -> String? {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            return inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(buffer.count)).map { _ in string(from: buffer) }
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            return inet_ntop(AF_INET6, &ipv6, &buffer, socklen_t(buffer.count)).map { _ in string(from: buffer) }
        }
        return nil
    }

    package static func isGlobalAddress(_ bytes: [UInt8]) -> Bool {
        if bytes.count == 4 {
            return isGlobalIPv4(bytes)
        }
        guard bytes.count == 16 else { return false }
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return isGlobalIPv4(Array(bytes[12..<16]))
        }
        if isWellKnownNAT64(bytes) || isLocalUseNAT64(bytes) {
            return false
        }

        // Conservatively admit only IPv6 global-unicast space (2000::/3).
        guard bytes[0] >= 0x20, bytes[0] <= 0x3f else { return false }
        if bytes[0] == 0x20, bytes[1] == 0x01 {
            if bytes[2] <= 0x01 { return false } // IANA protocol-assignment space.
            if bytes[2] == 0x0d, bytes[3] == 0xb8 { return false } // Documentation.
            if bytes[2] == 0x00, bytes[3] == 0x02 { return false } // Benchmarking.
        }
        if bytes[0] == 0x20, bytes[1] == 0x02 { return false } // 6to4 embeds an IPv4 route.
        if bytes[0] == 0x26, bytes[1] == 0x20, bytes[2] == 0x00, bytes[3] == 0x4f,
           bytes[4] == 0x80, bytes[5] == 0x00 { return false } // AS112 direct delegation.
        if bytes[0] == 0x3f, bytes[1] == 0xff, bytes[2] <= 0x0f { return false } // Documentation.

        // A network-specific NAT64 /96 can otherwise look like ordinary global IPv6.
        // Reject only unambiguously sensitive IPv4 tails so native addresses ending ::1 remain valid.
        if isSensitiveEmbeddedIPv4Tail(Array(bytes[12..<16])) { return false }
        return true
    }

    private static func isWellKnownNAT64(_ bytes: [UInt8]) -> Bool {
        bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xff && bytes[3] == 0x9b
            && bytes[4..<12].allSatisfy { $0 == 0 }
    }

    private static func isLocalUseNAT64(_ bytes: [UInt8]) -> Bool {
        bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xff
            && bytes[3] == 0x9b && bytes[4] == 0x00 && bytes[5] == 0x01
    }

    private static func isSensitiveEmbeddedIPv4Tail(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return true }
        let a = bytes[0], b = bytes[1]
        if a == 10 || a == 127 { return true }
        if a == 100, b >= 64, b <= 127 { return true }
        if a == 169, b == 254 { return true }
        if a == 172, b >= 16, b <= 31 { return true }
        if a == 192, b == 168 { return true }
        return false
    }

    private static func isGlobalIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let a = bytes[0], b = bytes[1], c = bytes[2]
        if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
        if a == 100, b >= 64, b <= 127 { return false }
        if a == 169, b == 254 { return false }
        if a == 172, b >= 16, b <= 31 { return false }
        if a == 192, b == 0, c == 0 { return false }
        if a == 192, b == 0, c == 2 { return false }
        if a == 192, b == 31, c == 196 { return false }
        if a == 192, b == 52, c == 193 { return false }
        if a == 192, b == 88, c == 99 { return false }
        if a == 192, b == 168 { return false }
        if a == 192, b == 175, c == 48 { return false }
        if a == 198, b == 18 || b == 19 { return false }
        if a == 198, b == 51, c == 100 { return false }
        if a == 203, b == 0, c == 113 { return false }
        return true
    }

    private static func string(from buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
