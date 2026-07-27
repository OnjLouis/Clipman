import Foundation

enum MobileStorageMode: String, CaseIterable, Identifiable, Sendable {
    case local
    case server

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct ClipmanSettings: Equatable, Sendable {
    var storageMode: MobileStorageMode
    var serverURL: String
    var serverToken: String
    var historyPassword: String
    var deviceName: String
    var soundsEnabled: Bool
    var hapticsEnabled: Bool
    var autoCopyRemote: Bool
    var addClipboardOnLaunch: Bool
    var requireAuthentication: Bool
    var linksEnabled: Bool
    var richTextEnabled: Bool

    @MainActor
    static var empty: ClipmanSettings {
        ClipmanSettings(
            storageMode: .server,
            serverURL: "",
            serverToken: "",
            historyPassword: "",
            deviceName: UIDeviceMachine.name,
            soundsEnabled: true,
            hapticsEnabled: true,
            autoCopyRemote: false,
            addClipboardOnLaunch: false,
            requireAuthentication: false,
            linksEnabled: true,
            richTextEnabled: false
        )
    }
}

enum SettingsStore {
    private enum Keys {
        static let serverURL = "serverURL"
        static let storageMode = "storageMode"
        static let soundsEnabled = "soundsEnabled"
        static let hapticsEnabled = "hapticsEnabled"
        static let autoCopyRemote = "autoCopyRemote"
        static let addClipboardOnLaunch = "addClipboardOnLaunch"
        static let requireAuthentication = "requireAuthentication"
        static let linksEnabled = "linksEnabled"
        static let richTextEnabled = "richTextEnabled"
        static let serverToken = "serverToken"
        static let historyPassword = "historyPassword"
        static let deviceName = "deviceName"
    }

    @MainActor
    static func load() -> ClipmanSettings {
        var settings = ClipmanSettings.empty
        settings.storageMode = MobileStorageMode(rawValue: UserDefaults.standard.string(forKey: Keys.storageMode) ?? "") ?? .server
        settings.serverURL = UserDefaults.standard.string(forKey: Keys.serverURL) ?? ""
        settings.soundsEnabled = UserDefaults.standard.object(forKey: Keys.soundsEnabled) as? Bool ?? true
        settings.hapticsEnabled = UserDefaults.standard.object(forKey: Keys.hapticsEnabled) as? Bool ?? true
        settings.autoCopyRemote = UserDefaults.standard.object(forKey: Keys.autoCopyRemote) as? Bool ?? false
        settings.addClipboardOnLaunch = UserDefaults.standard.object(forKey: Keys.addClipboardOnLaunch) as? Bool ?? false
        settings.requireAuthentication = UserDefaults.standard.object(forKey: Keys.requireAuthentication) as? Bool ?? false
        settings.linksEnabled = UserDefaults.standard.object(forKey: Keys.linksEnabled) as? Bool ?? true
        settings.richTextEnabled = UserDefaults.standard.object(forKey: Keys.richTextEnabled) as? Bool ?? false
        settings.deviceName = UserDefaults.standard.string(forKey: Keys.deviceName) ?? UIDeviceMachine.name
        if settings.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.deviceName = UIDeviceMachine.name
        }
        settings.serverToken = KeychainStore.string(for: Keys.serverToken)
        settings.historyPassword = KeychainStore.string(for: Keys.historyPassword)
        return settings
    }

    static func save(_ settings: ClipmanSettings) {
        UserDefaults.standard.set(settings.storageMode.rawValue, forKey: Keys.storageMode)
        UserDefaults.standard.set(settings.serverURL, forKey: Keys.serverURL)
        UserDefaults.standard.set(settings.soundsEnabled, forKey: Keys.soundsEnabled)
        UserDefaults.standard.set(settings.hapticsEnabled, forKey: Keys.hapticsEnabled)
        UserDefaults.standard.set(settings.autoCopyRemote, forKey: Keys.autoCopyRemote)
        UserDefaults.standard.set(settings.addClipboardOnLaunch, forKey: Keys.addClipboardOnLaunch)
        UserDefaults.standard.set(settings.requireAuthentication, forKey: Keys.requireAuthentication)
        UserDefaults.standard.set(settings.linksEnabled, forKey: Keys.linksEnabled)
        UserDefaults.standard.set(settings.richTextEnabled, forKey: Keys.richTextEnabled)
        UserDefaults.standard.set(settings.deviceName.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.deviceName)
        KeychainStore.set(settings.serverToken, for: Keys.serverToken)
        KeychainStore.set(settings.historyPassword, for: Keys.historyPassword)
    }
}
