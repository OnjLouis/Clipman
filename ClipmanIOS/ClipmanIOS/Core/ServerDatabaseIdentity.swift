import CryptoKit
import Foundation

enum ServerDatabaseIdentity {
    private static let purpose = "Clipman.ServerDatabaseId.v1"
    private static let noPasswordMarker = "<clipman-no-history-password>"

    static func fromTokenAndPassword(token: String, password: String) -> String {
        let cleanedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let passwordPart = password.isEmpty ? noPasswordMarker : password
        let key = SymmetricKey(data: SHA256.hash(data: Data(cleanedToken.utf8)))
        let message = Data((purpose + "\n" + passwordPart).utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return Data(mac)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
