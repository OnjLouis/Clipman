import Foundation
import Security

struct ShareSyncConfiguration: Codable, Equatable, Sendable {
    var storageMode: String
    var serverURL: String
    var serverCaCertPEM: String
    var serverCaHost: String
    var deviceName: String
    var richTextEnabled: Bool
    var includeImagesInRichText: Bool
}

struct ShareSyncSettings: Equatable, Sendable, ServerStorageSettingsProviding {
    var serverURL: String
    var serverToken: String
    var serverCaCertPEM: String
    var serverCaHost: String
    var historyPassword: String
    var deviceName: String
    var richTextEnabled: Bool
    var includeImagesInRichText: Bool
}

enum ShareSyncConfigurationError: Error, LocalizedError {
    case appGroupUnavailable
    case secureSettingsUnavailable
    case invalidConfiguration

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "Clipman's shared app storage is unavailable."
        case .secureSettingsUnavailable:
            "Clipman's protected server settings are unavailable. Open Clipman once and try again."
        case .invalidConfiguration:
            "Clipman Server is not configured for sharing."
        }
    }
}

enum ShareSyncConfigurationStore {
    private static let appGroup = "group.me.onj.clipman.ios"
    private static let directoryName = "ShareSync"
    private static let configurationName = "configuration.json"

    static func publish(
        storageMode: String,
        serverURL: String,
        serverToken: String,
        serverCaCertPEM: String,
        serverCaHost: String,
        historyPassword: String,
        deviceName: String,
        richTextEnabled: Bool,
        includeImagesInRichText: Bool
    ) {
        let configuration = ShareSyncConfiguration(
            storageMode: storageMode,
            serverURL: serverURL,
            serverCaCertPEM: serverCaCertPEM,
            serverCaHost: serverCaHost,
            deviceName: deviceName,
            richTextEnabled: richTextEnabled,
            includeImagesInRichText: richTextEnabled && includeImagesInRichText
        )
        guard SharedShareKeychain.set(serverToken, account: .serverToken),
              SharedShareKeychain.set(historyPassword, account: .historyPassword),
              let data = try? JSONEncoder().encode(configuration),
              let url = try? configurationURL(createDirectory: true) else {
            return
        }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    static func loadSettings() throws -> ShareSyncSettings {
        let url = try configurationURL(createDirectory: false)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let byteCount = values.fileSize,
              byteCount > 0,
              byteCount <= 64 * 1024 else {
            throw ShareSyncConfigurationError.invalidConfiguration
        }
        let configuration = try JSONDecoder().decode(
            ShareSyncConfiguration.self,
            from: Data(contentsOf: url)
        )
        guard configuration.storageMode == "server" else {
            throw ShareSyncConfigurationError.invalidConfiguration
        }
        guard let serverToken = SharedShareKeychain.string(account: .serverToken),
              let historyPassword = SharedShareKeychain.string(account: .historyPassword) else {
            throw ShareSyncConfigurationError.secureSettingsUnavailable
        }
        let settings = ShareSyncSettings(
            serverURL: configuration.serverURL,
            serverToken: serverToken,
            serverCaCertPEM: configuration.serverCaCertPEM,
            serverCaHost: configuration.serverCaHost,
            historyPassword: historyPassword,
            deviceName: configuration.deviceName,
            richTextEnabled: configuration.richTextEnabled,
            includeImagesInRichText: configuration.includeImagesInRichText
        )
        guard ServerStorageClient(settings: settings).isConfigured else {
            throw ShareSyncConfigurationError.invalidConfiguration
        }
        return settings
    }

    private static func configurationURL(createDirectory: Bool) throws -> URL {
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) else {
            throw ShareSyncConfigurationError.appGroupUnavailable
        }
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        if createDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent(configurationName, isDirectory: false)
    }
}

private enum SharedShareKeychain {
    enum Account: String {
        case serverToken = "server-token"
        case historyPassword = "history-password"
    }

    private static let service = "me.onj.clipman.ios.share-sync"
    private static let accessGroup = "83NN3HS237.me.onj.clipman.shared"

    static func string(account: Account) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    @discardableResult
    static func set(_ value: String, account: Account) -> Bool {
        let query = baseQuery(account: account)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func baseQuery(account: Account) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecAttrAccessGroup as String: accessGroup
        ]
    }
}
