import Foundation
import CCommonCrypto

public enum ServerDatabaseIdentity {
    private static let purpose = "Clipman.ServerDatabaseId.v1"
    private static let channelPurpose = "Clipman.ServerChannelId.v1"
    private static let syncRulesPurpose = "Clipman.ServerSyncRulesId.v1"

    public static func fromTokenAndPassword(token: String, password: String) -> String {
        let cleanedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedToken.isEmpty, !password.isEmpty else { return "" }
        let key = sha256(Array(cleanedToken.utf8))
        let message = Array((purpose + "\n" + password).utf8)
        return base64URL(hmacSHA256(key: key, data: message))
    }

    /// The bucket id of one sync channel (`sync-rules-spec.md` section 2).
    /// `channelKey` must already be the normalized key of section 3. A blank
    /// token, password or key yields an empty id, because channel sync needs
    /// server mode's mandatory history password.
    public static func channelDatabaseId(token: String, password: String, channelKey: String) -> String {
        let cleanedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedKey = channelKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedToken.isEmpty, !password.isEmpty, !cleanedKey.isEmpty else { return "" }
        let key = sha256(Array(cleanedToken.utf8))
        let message = Array((channelPurpose + "\n" + password + "\n" + cleanedKey).utf8)
        return base64URL(hmacSHA256(key: key, data: message))
    }

    /// The bucket id of the sync-rules document (`sync-rules-spec.md` section 2).
    public static func syncRulesDatabaseId(token: String, password: String) -> String {
        let cleanedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedToken.isEmpty, !password.isEmpty else { return "" }
        let key = sha256(Array(cleanedToken.utf8))
        let message = Array((syncRulesPurpose + "\n" + password).utf8)
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
