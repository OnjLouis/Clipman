import CryptoKit
import Foundation

enum ServerDatabaseIdentity {
    private static let purpose = "Clipman.ServerDatabaseId.v1"
    private static let channelPurpose = "Clipman.ServerChannelId.v1"
    private static let syncRulesPurpose = "Clipman.ServerSyncRulesId.v1"

    static func fromTokenAndPassword(token: String, password: String) -> String {
        let cleanedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedToken.isEmpty, !password.isEmpty else { return "" }
        return derive(token: cleanedToken, message: purpose + "\n" + password)
    }

    /// The bucket id of one sync channel (`sync-rules-spec.md` section 2).
    /// `channelKey` must already be the normalized key of section 3. A blank
    /// token, password or key yields an empty id, because channel sync needs
    /// server mode's mandatory history password.
    static func channelDatabaseId(token: String, password: String, channelKey: String) -> String {
        let cleanedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedKey = channelKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedToken.isEmpty, !password.isEmpty, !cleanedKey.isEmpty else { return "" }
        return derive(token: cleanedToken, message: channelPurpose + "\n" + password + "\n" + cleanedKey)
    }

    /// The bucket id of the sync-rules document (`sync-rules-spec.md` section 2).
    static func syncRulesDatabaseId(token: String, password: String) -> String {
        let cleanedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedToken.isEmpty, !password.isEmpty else { return "" }
        return derive(token: cleanedToken, message: syncRulesPurpose + "\n" + password)
    }

    private static func derive(token cleanedToken: String, message: String) -> String {
        let key = SymmetricKey(data: SHA256.hash(data: Data(cleanedToken.utf8)))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return Data(mac)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
