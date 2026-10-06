import Foundation
import Security

enum ReleaseSignature {
    static func verify(digest: String, signature: Data) throws {
        guard signature.count == 384, digest.count == 64,
              digest.unicodeScalars.allSatisfy({ "0123456789abcdef".unicodeScalars.contains($0) }) else {
            throw failure("The server release signature is missing or malformed.")
        }
        let encoded = "MIIBigKCAYEA2scaX5h0TMLe8EPz8m7Iuue0CQPDWf3RblD64PxZeZjmngTU49BNCnJ7NdayMRQE8XQOmzBsQsq37qvMmGrXO5Rc9j/qRQxxb7WZn+Tb9Akqzzuw07DVtrf+uKBtaJ49y6Mb9Js+uUi+ODo/yrVxoXLf/aca0oqu3uKIrW+0nYIcz8J+Q+9IrMa7HODmNEr4zJcv5QJdmxwYEDT3Au7yorMMZz8Q3+IaGmq21GDp9I7Fke7iH8h2creF0tUqKyEpNvDW5DpbrEPTxtEtlcG4DhXdYqNJ53Yh+2FKUYe9AUTBDB1ydCbJaP4HZkdKwjgcEfcLcH6+G4VU6j9c7mBM8RnsBX2bcUmRtmD+5N8Glio9Ge2Cn4kmt3Yb63FjmaOaZahaIWkzTU5dPyELaGpQzmUNugWuKVdaOqePGb6UD7DLb5LRATDPbr361ruegglHKOdT3d9ZpQYBCTLMB40zdvTI+eHA4YDHK6SLeI4LKaPIVwJKVmny56yUslySRTU7AgMBAAE="
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                                         kSecAttrKeyClass: kSecAttrKeyClassPublic,
                                         kSecAttrKeySizeInBits: 3072]
        guard let data = Data(base64Encoded: encoded),
              let key = SecKeyCreateWithData(data as CFData, attributes as CFDictionary, nil) else {
            throw failure("The server release verification key is invalid.")
        }
        let message = Data("Clipman Server ZIP\n\(digest)\n".utf8)
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                    message as CFData, signature as CFData, nil) else {
            throw failure("The server release publisher signature is invalid.")
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "ClipmanServerUpdate", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
