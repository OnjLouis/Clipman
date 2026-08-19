import Foundation

enum MobileStorageMode: String, CaseIterable, Identifiable, Sendable {
    case local
    case server

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum HistorySortMode: String, CaseIterable, Identifiable, Sendable {
    case manual
    case newest
    case oldest
    case text

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual: return "Manual"
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .text: return "Text"
        }
    }

    var accessibilityActionLabel: String { "Set sort to \(label)" }

    var next: HistorySortMode {
        switch self {
        case .manual: return .newest
        case .newest: return .oldest
        case .oldest: return .text
        case .text: return .manual
        }
    }

    static func normalized(_ rawValue: String?) -> HistorySortMode {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let mode = HistorySortMode(rawValue: value) else {
            return .manual
        }
        return mode
    }
}

enum HistorySortAccessibilityOrder {
    // SwiftUI presents chained named accessibility actions in reverse modifier order.
    static let sourceModifierModes: [HistorySortMode] = [.text, .oldest, .newest, .manual]
    static var voiceOverPresentedModes: [HistorySortMode] { Array(sourceModifierModes.reversed()) }
}

enum HistoryPresentationSorter {
    static func ordered(_ entries: [ClipEntry], mode: HistorySortMode) -> [ClipEntry] {
        let indexed = Array(entries.enumerated())
        let pinned = indexed
            .filter { $0.element.Pinned }
            .sorted(by: manualOrder)
        let normal = indexed
            .filter { !$0.element.Pinned }
            .sorted { left, right in
                switch mode {
                case .manual:
                    return manualOrder(left, right)
                case .newest:
                    if left.element.LastUsedUnixMs != right.element.LastUsedUnixMs {
                        return left.element.LastUsedUnixMs > right.element.LastUsedUnixMs
                    }
                case .oldest:
                    if left.element.LastUsedUnixMs != right.element.LastUsedUnixMs {
                        return left.element.LastUsedUnixMs < right.element.LastUsedUnixMs
                    }
                case .text:
                    let comparison = left.element.displayText.localizedCaseInsensitiveCompare(right.element.displayText)
                    if comparison != .orderedSame { return comparison == .orderedAscending }
                }
                return left.offset < right.offset
            }
        return (pinned + normal).map(\.element)
    }

    private static func manualOrder(
        _ left: EnumeratedSequence<[ClipEntry]>.Element,
        _ right: EnumeratedSequence<[ClipEntry]>.Element
    ) -> Bool {
        let leftOrder = left.element.ManualOrder <= 0 ? Int64.max : left.element.ManualOrder
        let rightOrder = right.element.ManualOrder <= 0 ? Int64.max : right.element.ManualOrder
        if leftOrder != rightOrder { return leftOrder < rightOrder }
        if left.element.CreatedUnixMs != right.element.CreatedUnixMs {
            return left.element.CreatedUnixMs < right.element.CreatedUnixMs
        }
        return left.offset < right.offset
    }
}

struct ClipmanSettings: Equatable, Sendable {
    var storageMode: MobileStorageMode
    var serverURL: String
    var serverToken: String
    var serverCaCertPEM: String
    var serverCaHost: String
    var historyPassword: String
    var deviceName: String
    var soundsEnabled: Bool
    var hapticsEnabled: Bool
    var autoCopyRemote: Bool
    var addClipboardOnLaunch: Bool
    var requireAuthentication: Bool
    var linksEnabled: Bool
    var richTextEnabled: Bool
    var includeImagesInRichText: Bool
    var historySortMode: HistorySortMode
    var confirmDeletions: Bool
    var cloudBackupEnabled: Bool
    var cloudBackupBookmark: Data
    var cloudBackupFolderName: String

    @MainActor
    static var empty: ClipmanSettings {
        ClipmanSettings(
            storageMode: .server,
            serverURL: "",
            serverToken: "",
            serverCaCertPEM: "",
            serverCaHost: "",
            historyPassword: "",
            deviceName: UIDeviceMachine.name,
            soundsEnabled: true,
            hapticsEnabled: true,
            autoCopyRemote: false,
            addClipboardOnLaunch: false,
            requireAuthentication: false,
            linksEnabled: true,
            richTextEnabled: false,
            includeImagesInRichText: false,
            historySortMode: .manual,
            confirmDeletions: true,
            cloudBackupEnabled: false,
            cloudBackupBookmark: Data(),
            cloudBackupFolderName: ""
        )
    }
}

extension ClipmanSettings: ServerStorageSettingsProviding {}

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
        static let includeImagesInRichText = "includeImagesInRichText"
        static let historySortMode = "historySortMode"
        static let confirmDeletions = "confirmDeletions"
        static let serverToken = "serverToken"
        static let serverCaCertPEM = "serverCaCertPEM"
        static let serverCaHost = "serverCaHost"
        static let historyPassword = "historyPassword"
        static let deviceName = "deviceName"
        static let cloudBackupEnabled = "cloudBackupEnabled"
        static let cloudBackupBookmark = "cloudBackupBookmark"
        static let cloudBackupFolderName = "cloudBackupFolderName"
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
        settings.includeImagesInRichText = settings.richTextEnabled
            && (UserDefaults.standard.object(forKey: Keys.includeImagesInRichText) as? Bool ?? false)
        settings.historySortMode = loadHistorySort(from: UserDefaults.standard)
        settings.confirmDeletions = UserDefaults.standard.object(forKey: Keys.confirmDeletions) as? Bool ?? true
        settings.cloudBackupEnabled = UserDefaults.standard.object(forKey: Keys.cloudBackupEnabled) as? Bool ?? false
        settings.cloudBackupBookmark = UserDefaults.standard.data(forKey: Keys.cloudBackupBookmark) ?? Data()
        settings.cloudBackupFolderName = UserDefaults.standard.string(forKey: Keys.cloudBackupFolderName) ?? ""
        if settings.cloudBackupBookmark.isEmpty {
            settings.cloudBackupEnabled = false
            settings.cloudBackupFolderName = ""
        }
        settings.deviceName = UserDefaults.standard.string(forKey: Keys.deviceName) ?? UIDeviceMachine.name
        if settings.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.deviceName = UIDeviceMachine.name
        }
        settings.serverToken = KeychainStore.string(for: Keys.serverToken)
        settings.serverCaCertPEM = UserDefaults.standard.string(forKey: Keys.serverCaCertPEM) ?? ""
        settings.serverCaHost = UserDefaults.standard.string(forKey: Keys.serverCaHost) ?? ""
        if let authority = try? ServerSettingsSanitizer.parseCertificateAuthority(settings.serverCaCertPEM, address: settings.serverURL) {
            if settings.serverCaHost.isEmpty || settings.serverCaHost.caseInsensitiveCompare(authority.host) == .orderedSame {
                settings.serverCaCertPEM = authority.pem
                settings.serverCaHost = authority.host
            } else {
                settings.serverCaCertPEM = ""
                settings.serverCaHost = ""
            }
        } else if !settings.serverCaCertPEM.isEmpty {
            settings.serverCaCertPEM = ""
            settings.serverCaHost = ""
        }
        settings.historyPassword = KeychainStore.string(for: Keys.historyPassword)
        publishShareSettings(settings)
        return settings
    }

    static func save(_ settings: ClipmanSettings) {
        UserDefaults.standard.set(settings.storageMode.rawValue, forKey: Keys.storageMode)
        UserDefaults.standard.set(settings.serverURL, forKey: Keys.serverURL)
        UserDefaults.standard.set(settings.serverCaCertPEM, forKey: Keys.serverCaCertPEM)
        UserDefaults.standard.set(settings.serverCaHost, forKey: Keys.serverCaHost)
        UserDefaults.standard.set(settings.soundsEnabled, forKey: Keys.soundsEnabled)
        UserDefaults.standard.set(settings.hapticsEnabled, forKey: Keys.hapticsEnabled)
        UserDefaults.standard.set(settings.autoCopyRemote, forKey: Keys.autoCopyRemote)
        UserDefaults.standard.set(settings.addClipboardOnLaunch, forKey: Keys.addClipboardOnLaunch)
        UserDefaults.standard.set(settings.requireAuthentication, forKey: Keys.requireAuthentication)
        UserDefaults.standard.set(settings.linksEnabled, forKey: Keys.linksEnabled)
        UserDefaults.standard.set(settings.richTextEnabled, forKey: Keys.richTextEnabled)
        UserDefaults.standard.set(settings.richTextEnabled && settings.includeImagesInRichText, forKey: Keys.includeImagesInRichText)
        saveHistorySort(settings.historySortMode, to: UserDefaults.standard)
        UserDefaults.standard.set(settings.confirmDeletions, forKey: Keys.confirmDeletions)
        UserDefaults.standard.set(settings.cloudBackupEnabled, forKey: Keys.cloudBackupEnabled)
        UserDefaults.standard.set(settings.cloudBackupBookmark, forKey: Keys.cloudBackupBookmark)
        UserDefaults.standard.set(settings.cloudBackupFolderName, forKey: Keys.cloudBackupFolderName)
        UserDefaults.standard.set(settings.deviceName.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.deviceName)
        KeychainStore.set(settings.serverToken, for: Keys.serverToken)
        KeychainStore.set(settings.historyPassword, for: Keys.historyPassword)
        publishShareSettings(settings)
    }

    static func loadHistorySort(from defaults: UserDefaults) -> HistorySortMode {
        HistorySortMode.normalized(defaults.string(forKey: Keys.historySortMode))
    }

    static func saveHistorySort(_ mode: HistorySortMode, to defaults: UserDefaults) {
        defaults.set(mode.rawValue, forKey: Keys.historySortMode)
    }

    private static func publishShareSettings(_ settings: ClipmanSettings) {
        ShareSyncConfigurationStore.publish(
            storageMode: settings.storageMode.rawValue,
            serverURL: settings.serverURL,
            serverToken: settings.serverToken,
            serverCaCertPEM: settings.serverCaCertPEM,
            serverCaHost: settings.serverCaHost,
            historyPassword: settings.historyPassword,
            deviceName: settings.deviceName,
            richTextEnabled: settings.richTextEnabled,
            includeImagesInRichText: settings.includeImagesInRichText
        )
    }
}
