import Foundation
import Security

enum ClipDatabaseError: Error, LocalizedError, Equatable {
    case passwordRequired
    case incorrectPassword
    case incompleteEncryptedDatabase
    case unsupportedEncryptedVersion(UInt8)
    case databaseFileTooLarge
    case encodedDatabaseTooLarge
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .passwordRequired:
            "This Clipman database is encrypted and needs its history password."
        case .incorrectPassword:
            "The Clipman database password is incorrect."
        case .incompleteEncryptedDatabase:
            "The encrypted Clipman database is incomplete."
        case .unsupportedEncryptedVersion:
            "This encrypted Clipman database uses an unsupported format."
        case .databaseFileTooLarge:
            "The Clipman database exceeds the 272 MiB container safety limit."
        case .encodedDatabaseTooLarge:
            "The Clipman database exceeds the 256 MiB decoded safety limit."
        case .unsupportedFormat(let message):
            message
        }
    }
}

enum ClipDatabaseFile {
    private typealias DerivedKeys = (encryptionKey: [UInt8], macKey: [UInt8])

    private final class DerivedKeyCache: @unchecked Sendable {
        private struct PersistedEntry: Codable {
            var id: Data
            var keyMaterial: Data
        }

        private struct PersistedCache: Codable {
            var entries: [PersistedEntry]
        }

        private let lock = NSLock()
        private var order: [Data] = []
        private var values: [Data: DerivedKeys] = [:]
        private let capacity = 8
        private let keychainService = "me.onj.clipman.ios.database-derived-keys"
        private let keychainAccount = "cache-v1"

        init() {
            loadPersistedValues()
        }

        func value(for id: Data) -> DerivedKeys? {
            lock.lock()
            defer { lock.unlock() }
            guard let value = values[id] else { return nil }
            order.removeAll { $0 == id }
            order.append(id)
            return value
        }

        func insert(_ value: DerivedKeys, for id: Data) {
            lock.lock()
            defer { lock.unlock() }
            order.removeAll { $0 == id }
            order.append(id)
            values[id] = value
            while order.count > capacity {
                values.removeValue(forKey: order.removeFirst())
            }
            persistLocked()
        }

        private func loadPersistedValues() {
            var query = keychainQuery()
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data,
                  data.count <= 16_384,
                  let persisted = try? PropertyListDecoder().decode(PersistedCache.self, from: data) else {
                return
            }
            for entry in persisted.entries.suffix(capacity) where entry.id.count == 32 && entry.keyMaterial.count == 64 {
                order.append(entry.id)
                values[entry.id] = (
                    Array(entry.keyMaterial.prefix(32)),
                    Array(entry.keyMaterial.suffix(32))
                )
            }
        }

        private func persistLocked() {
            let entries = order.compactMap { id -> PersistedEntry? in
                guard let value = values[id] else { return nil }
                return PersistedEntry(id: id, keyMaterial: Data(value.encryptionKey + value.macKey))
            }
            guard let data = try? PropertyListEncoder().encode(PersistedCache(entries: entries)) else { return }
            let query = keychainQuery()
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                SecItemAdd(add as CFDictionary, nil)
            }
        }

        private func keychainQuery() -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: keychainAccount
            ]
        }
    }

    static let compressedMagic = Data("CLIPDB1".utf8)
    static let encryptedMagic = Data("CLIPDB2".utf8)
    static let maximumFileBytes = 272 * 1024 * 1024
    static let maximumEncodedJSONBytes = Gzip.maximumDecompressedBytes
    private static let encryptedEnvelopeBytes = encryptedMagic.count + 1 + 16 + 16 + 32
    private static let derivedKeyCache = DerivedKeyCache()

    static func load(_ data: Data, password: String) throws -> ClipDatabase {
        if data.isEmpty { return ClipDatabase() }
        try validateFileSize(data.count)

        let jsonData: Data
        if data.starts(with: encryptedMagic) {
            jsonData = try readEncrypted(data, password: password)
        } else {
            let payload = data.starts(with: compressedMagic) ? data.dropFirst(compressedMagic.count) : data[...]
            jsonData = try Gzip.decompress(Data(payload))
        }
        return try JSONDecoder().decode(ClipDatabase.self, from: jsonData)
    }

    static func save(
        _ database: ClipDatabase,
        password: String,
        preferredSalt: [UInt8]? = nil
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let json = try encoder.encode(database)
        try validateEncodedJSONSize(json.count)
        let result: Data
        if password.isEmpty {
            do {
                result = compressedMagic + (try Gzip.compress(
                    json,
                    maximumOutputBytes: maximumFileBytes - compressedMagic.count
                ))
            } catch GzipError.compressedOutputTooLarge {
                throw ClipDatabaseError.databaseFileTooLarge
            }
        } else {
            result = try writeEncrypted(json: json, password: password, preferredSalt: preferredSalt)
        }
        try validateFileSize(result.count)
        return result
    }

    static func validateFileSize(_ byteCount: Int) throws {
        guard byteCount >= 0, byteCount <= maximumFileBytes else {
            throw ClipDatabaseError.databaseFileTooLarge
        }
    }

    static func validateEncodedJSONSize(_ byteCount: Int) throws {
        guard byteCount >= 0, byteCount <= maximumEncodedJSONBytes else {
            throw ClipDatabaseError.encodedDatabaseTooLarge
        }
    }

    static func readBounded(from url: URL, maximumBytes: Int = maximumFileBytes) throws -> Data {
        guard maximumBytes >= 0 else { throw ClipDatabaseError.databaseFileTooLarge }
        let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize <= maximumBytes else { throw ClipDatabaseError.databaseFileTooLarge }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(fileSize)
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard chunk.count <= maximumBytes - data.count else {
                throw ClipDatabaseError.databaseFileTooLarge
            }
            data.append(chunk)
        }
        return data
    }

    static func encryptedSalt(from data: Data) -> [UInt8]? {
        let saltOffset = encryptedMagic.count + 1
        guard data.starts(with: encryptedMagic),
              data.count >= saltOffset + 16,
              data[encryptedMagic.count] == 1 else {
            return nil
        }
        return Array(data[saltOffset..<saltOffset + 16])
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

    private static func writeEncrypted(json: Data, password: String, preferredSalt: [UInt8]?) throws -> Data {
        let salt = preferredSalt.flatMap { $0.count == 16 ? $0 : nil } ?? randomBytes(count: 16)
        let iv = randomBytes(count: 16)
        let keys = try deriveKeys(password: password, salt: salt)
        let maximumCompressedBytes = maximumFileBytes - encryptedEnvelopeBytes - kCCBlockSizeAES128
        let compressed: [UInt8]
        do {
            compressed = Array(try Gzip.compress(json, maximumOutputBytes: maximumCompressedBytes))
        } catch GzipError.compressedOutputTooLarge {
            throw ClipDatabaseError.databaseFileTooLarge
        }
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

    private static func deriveKeys(password: String, salt: [UInt8]) throws -> DerivedKeys {
        let cacheID = derivedKeyCacheID(password: password, salt: salt)
        if let cached = derivedKeyCache.value(for: cacheID) {
            return cached
        }
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
        let keys: DerivedKeys = (Array(derived[0..<32]), Array(derived[32..<64]))
        derivedKeyCache.insert(keys, for: cacheID)
        return keys
    }

    private static func derivedKeyCacheID(password: String, salt: [UInt8]) -> Data {
        var material = Data(password.utf8)
        material.append(0)
        material.append(contentsOf: salt)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        material.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(bytes.count), &digest)
        }
        return Data(digest)
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
