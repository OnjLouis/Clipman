import Foundation
import CCommonCrypto

public enum ServerDatabaseIdentity {
    private static let purpose = "Clipman.ServerDatabaseId.v1"
    public static func fromTokenAndPassword(token: String, password: String) -> String {
        let cleanedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedToken.isEmpty, !password.isEmpty else { return "" }
        let key = sha256(Array(cleanedToken.utf8))
        let message = Array((purpose + "\n" + password).utf8)
        return base64URL(hmacSHA256(key: key, data: message))
    }

    private static func sha256(_ data: [UInt8]) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256(data, CC_LONG(data.count), &digest)
        return digest
    }

    private static func hmacSHA256(key: [UInt8], data: [UInt8]) -> [UInt8] {
        var mac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), key, key.count, data, data.count, &mac)
        return mac
    }

    private static func base64URL(_ data: [UInt8]) -> String {
        Data(data)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
