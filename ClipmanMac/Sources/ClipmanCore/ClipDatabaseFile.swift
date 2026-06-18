import Foundation
import Security
import CCommonCrypto

public enum ClipDatabaseError: Error, LocalizedError, Equatable {
    case passwordRequired
    case incorrectPassword
    case incompleteEncryptedDatabase
    case unsupportedEncryptedVersion(UInt8)
    case unsupportedFormat(String)

    public var errorDescription: String? {
        switch self {
        case .passwordRequired:
            "This Clipman database is encrypted and needs its history password."
        case .incorrectPassword:
            "The Clipman database password is incorrect."
        case .incompleteEncryptedDatabase:
            "The encrypted Clipman database is incomplete."
        case .unsupportedEncryptedVersion:
            "This encrypted Clipman database uses an unsupported format."
        case .unsupportedFormat(let message):
            message
        }
    }
}

public enum ClipDatabaseFile {
    public static let compressedMagic = Data("CLIPDB1".utf8)
    public static let encryptedMagic = Data("CLIPDB2".utf8)

    public static func isEncryptedFile(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return false }
        return data.starts(with: encryptedMagic)
    }

    public static func load(_ url: URL, password: String = "") throws -> ClipDatabase {
        try loadCodable(url, password: password, defaultValue: ClipDatabase())
    }

    public static func loadCodable<T: Decodable>(_ url: URL, password: String = "", defaultValue: T) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return defaultValue
        }
        let data = try Data(contentsOf: url)
        if data.isEmpty {
            return defaultValue
        }

        let jsonData: Data
        if data.starts(with: encryptedMagic) {
            jsonData = try readEncrypted(data, password: password)
        } else if url.pathExtension.lowercased() == "clipdb" {
            let payload = data.starts(with: compressedMagic) ? data.dropFirst(compressedMagic.count) : data[...]
            jsonData = try Gzip.decompress(Data(payload))
        } else {
            jsonData = data
        }
        return try decode(jsonData, as: T.self)
    }

    public static func saveAtomic(_ url: URL, database: ClipDatabase, password: String = "") throws {
        try saveAtomicCodable(url, value: database, password: password)
    }

    public static func saveAtomicCodable<T: Encodable>(_ url: URL, value: T, password: String = "") throws {
        let data: Data
        if !password.isEmpty && url.pathExtension.lowercased() == "clipdb" {
            data = try writeEncrypted(url, value: value, password: password)
        } else if url.pathExtension.lowercased() == "clipdb" {
            let json = try encode(value)
            data = compressedMagic + (try Gzip.compress(json))
        } else {
            data = try encode(value)
        }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.appendingPathExtension("tmp")
        try data.write(to: temp, options: [.atomic])
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
    }

    private static func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func readEncrypted(_ data: Data, password: String) throws -> Data {
        guard !password.isEmpty else { throw ClipDatabaseError.passwordRequired }
        guard data.count >= encryptedMagic.count + 1 + 16 + 16 + 32 else {
            throw ClipDatabaseError.incompleteEncryptedDatabase
        }
        var offset = encryptedMagic.count
        let version = data[offset]
        offset += 1
        guard version == 1 else { throw ClipDatabaseError.unsupportedEncryptedVersion(version) }
        let salt = Array(data[offset..<offset + 16])
        offset += 16
        let iv = Array(data[offset..<offset + 16])
        offset += 16
        let cipherEnd = data.count - 32
        let cipher = Array(data[offset..<cipherEnd])
        let expectedMac = Array(data[cipherEnd..<data.count])
        let signed = Array(data[0..<cipherEnd])
        let keys = try deriveKeys(password: password, salt: salt)
        let actualMac = hmacSHA256(key: keys.macKey, data: signed)
        guard constantTimeEqual(actualMac, expectedMac) else {
            throw ClipDatabaseError.incorrectPassword
        }
        let decrypted = try aesCBC(data: cipher, key: keys.encryptionKey, iv: iv, operation: CCOperation(kCCDecrypt))
        return try Gzip.decompress(Data(decrypted))
    }

    private static func writeEncrypted<T: Encodable>(_ url: URL, value: T, password: String) throws -> Data {
        let salt = existingEncryptedSalt(url) ?? randomBytes(count: 16)
        let iv = randomBytes(count: 16)
        let keys = try deriveKeys(password: password, salt: salt)
        let json = try encode(value)
        let compressed = Array(try Gzip.compress(json))
        let cipher = try aesCBC(data: compressed, key: keys.encryptionKey, iv: iv, operation: CCOperation(kCCEncrypt))
        var signed = Data()
        signed.append(encryptedMagic)
        signed.append(1)
        signed.append(contentsOf: salt)
        signed.append(contentsOf: iv)
        signed.append(contentsOf: cipher)
        let mac = hmacSHA256(key: keys.macKey, data: Array(signed))
        signed.append(contentsOf: mac)
        return signed
    }

    private static func existingEncryptedSalt(_ url: URL) -> [UInt8]? {
        guard let data = try? Data(contentsOf: url),
              data.starts(with: encryptedMagic),
              data.count >= encryptedMagic.count + 1 + 16 else {
            return nil
        }
        let start = encryptedMagic.count + 1
        return Array(data[start..<start + 16])
    }

    private static func deriveKeys(password: String, salt: [UInt8]) throws -> (encryptionKey: [UInt8], macKey: [UInt8]) {
        var derived = [UInt8](repeating: 0, count: 64)
        let status = password.withCString { passwordPointer in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordPointer,
                strlen(passwordPointer),
                salt,
                salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                150_000,
                &derived,
                derived.count
            )
        }
        guard status == kCCSuccess else {
            throw ClipDatabaseError.unsupportedFormat("Could not derive encryption keys.")
        }
        return (Array(derived[0..<32]), Array(derived[32..<64]))
    }

    private static func hmacSHA256(key: [UInt8], data: [UInt8]) -> [UInt8] {
        var mac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), key, key.count, data, data.count, &mac)
        return mac
    }

    private static func aesCBC(data: [UInt8], key: [UInt8], iv: [UInt8], operation: CCOperation) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var outputLength = 0
        let status = CCCrypt(
            operation,
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding),
            key,
            key.count,
            iv,
            data,
            data.count,
            &output,
            output.count,
            &outputLength
        )
        guard status == kCCSuccess else {
            throw ClipDatabaseError.unsupportedFormat("AES-CBC operation failed with status \(status).")
        }
        return Array(output.prefix(outputLength))
    }

    private static func randomBytes(count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes
    }

    private static func constantTimeEqual(_ left: [UInt8], _ right: [UInt8]) -> Bool {
        guard left.count == right.count else { return false }
        var diff: UInt8 = 0
        for index in left.indices {
            diff |= left[index] ^ right[index]
        }
        return diff == 0
    }
}
