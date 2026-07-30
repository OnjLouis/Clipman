import Foundation
import Carbon

struct ClipmanSettings: Codable, Equatable {
    var machineName: String
    var deviceName: String
    var databasePath: String
    var storageMode: String
    var serverUrl: String
    var serverToken: String
    var serverCaCertPem: String
    var serverCaHost: String
    var monitoringEnabled: Bool
    var soundsEnabled: Bool
    var showHistoryHotkey: HotkeyDescriptor
    var toggleMonitoringHotkey: HotkeyDescriptor
    var windowFrame: String
    var sortMode: String
    var sortDescending: Bool
    var fileHistorySortMode: String
    var fileHistorySortDescending: Bool
    var lastSelectedTab: Int
    var lastSelectedHistoryTab: String
    var historyTabOrder: [String]
    var linksHistoryEnabled: Bool
    var richTextHistoryEnabled: Bool
    var groupFilter: String
    var historyFilterType: String
    var deviceFilter: String
    var confirmDeletions: Bool
    var runAtStartup: Bool
    var captureClipboardOnStartup: Bool
    var rememberDatabasePassword: Bool
    var autoCopyLatestRemoteText: Bool
    var pasteAfterEnter: Bool
    var dynamicHistoryMode: Bool
    var updateCheckFrequency: String
    var installUpdatesSilently: Bool
    var lastUpdateCheckUnixMs: Int64
    var quickCopyHotkeys: [String: HotkeyDescriptor]
    var quickPasteModes: [String: String]
    var ignoredApplications: [String]
    var sensitiveDataMode: String
    var sensitiveDataPresetIds: [String]

    enum CodingKeys: String, CodingKey {
        case machineName, deviceName, databasePath, storageMode = "StorageMode", serverUrl = "ServerUrl", serverToken = "ServerToken", serverCaCertPem = "ServerCaCertPem", serverCaHost = "ServerCaHost", monitoringEnabled, soundsEnabled, showHistoryHotkey, toggleMonitoringHotkey, windowFrame
        case sortMode, sortDescending, fileHistorySortMode, fileHistorySortDescending, lastSelectedTab, lastSelectedHistoryTab, historyTabOrder, linksHistoryEnabled, richTextHistoryEnabled, groupFilter, historyFilterType, deviceFilter, confirmDeletions, runAtStartup
        case captureClipboardOnStartup
        case rememberDatabasePassword
        case autoCopyLatestRemoteText, pasteAfterEnter, dynamicHistoryMode, updateCheckFrequency, installUpdatesSilently, lastUpdateCheckUnixMs, quickCopyHotkeys, quickPasteModes
        case ignoredApplications
        case sensitiveDataMode = "SensitiveDataMode"
        case sensitiveDataPresetIds = "SensitiveDataPresetIds"
        case ignoredProcesses = "IgnoredProcesses"
        case legacyQuickCopyHotkey = "quickCopyHotkey"
        case legacyQuickCopyEntryID = "quickCopyEntryID"
    }

    init(
        machineName: String,
        deviceName: String,
        databasePath: String,
        storageMode: String,
        serverUrl: String,
        serverToken: String,
        serverCaCertPem: String,
        serverCaHost: String,
        monitoringEnabled: Bool,
        soundsEnabled: Bool,
        showHistoryHotkey: HotkeyDescriptor,
        toggleMonitoringHotkey: HotkeyDescriptor,
        windowFrame: String,
        sortMode: String,
        sortDescending: Bool,
        fileHistorySortMode: String,
        fileHistorySortDescending: Bool,
        lastSelectedTab: Int,
        lastSelectedHistoryTab: String,
        historyTabOrder: [String],
        linksHistoryEnabled: Bool,
        richTextHistoryEnabled: Bool,
        groupFilter: String,
        historyFilterType: String,
        deviceFilter: String,
        confirmDeletions: Bool,
        runAtStartup: Bool,
        captureClipboardOnStartup: Bool,
        rememberDatabasePassword: Bool,
        autoCopyLatestRemoteText: Bool,
        pasteAfterEnter: Bool,
        dynamicHistoryMode: Bool,
        updateCheckFrequency: String,
        installUpdatesSilently: Bool,
        lastUpdateCheckUnixMs: Int64,
        quickCopyHotkeys: [String: HotkeyDescriptor],
        quickPasteModes: [String: String],
        ignoredApplications: [String],
        sensitiveDataMode: String,
        sensitiveDataPresetIds: [String]
    ) {
        self.machineName = machineName
        self.deviceName = deviceName
        self.databasePath = databasePath
        self.storageMode = storageMode
        self.serverUrl = serverUrl
        self.serverToken = serverToken
        self.serverCaCertPem = serverCaCertPem
        self.serverCaHost = serverCaHost
        self.monitoringEnabled = monitoringEnabled
        self.soundsEnabled = soundsEnabled
        self.showHistoryHotkey = showHistoryHotkey
        self.toggleMonitoringHotkey = toggleMonitoringHotkey
        self.windowFrame = windowFrame
        self.sortMode = sortMode
        self.sortDescending = sortDescending
        self.fileHistorySortMode = fileHistorySortMode
        self.fileHistorySortDescending = fileHistorySortDescending
        self.lastSelectedTab = lastSelectedTab
        self.lastSelectedHistoryTab = lastSelectedHistoryTab
        self.historyTabOrder = HistoryTabID.normalizeOrder(historyTabOrder)
        self.linksHistoryEnabled = linksHistoryEnabled
        self.richTextHistoryEnabled = richTextHistoryEnabled
        self.groupFilter = groupFilter
        self.historyFilterType = historyFilterType
        self.deviceFilter = deviceFilter
        self.confirmDeletions = confirmDeletions
        self.runAtStartup = runAtStartup
        self.captureClipboardOnStartup = captureClipboardOnStartup
        self.rememberDatabasePassword = rememberDatabasePassword
        self.autoCopyLatestRemoteText = autoCopyLatestRemoteText
        self.pasteAfterEnter = pasteAfterEnter
        self.dynamicHistoryMode = dynamicHistoryMode
        self.updateCheckFrequency = updateCheckFrequency
        self.installUpdatesSilently = installUpdatesSilently
        self.lastUpdateCheckUnixMs = lastUpdateCheckUnixMs
        self.quickCopyHotkeys = quickCopyHotkeys
        self.quickPasteModes = quickPasteModes
        self.ignoredApplications = ignoredApplications
        self.sensitiveDataMode = sensitiveDataMode
        self.sensitiveDataPresetIds = sensitiveDataPresetIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ClipmanSettings.defaults(applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Clipman", isDirectory: true))
        machineName = try container.decodeIfPresent(String.self, forKey: .machineName) ?? fallback.machineName
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName) ?? machineName
        databasePath = try container.decodeIfPresent(String.self, forKey: .databasePath) ?? fallback.databasePath
        storageMode = ClipmanSettings.normalizeStorageMode(try container.decodeIfPresent(String.self, forKey: .storageMode))
        serverUrl = ServerSettingsSanitizer.cleanURL(try container.decodeIfPresent(String.self, forKey: .serverUrl) ?? "")
        serverToken = ServerSettingsSanitizer.cleanToken(try container.decodeIfPresent(String.self, forKey: .serverToken) ?? "")
        serverCaCertPem = try container.decodeIfPresent(String.self, forKey: .serverCaCertPem) ?? ""
        serverCaHost = try container.decodeIfPresent(String.self, forKey: .serverCaHost) ?? ""
        monitoringEnabled = try container.decodeIfPresent(Bool.self, forKey: .monitoringEnabled) ?? fallback.monitoringEnabled
        soundsEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundsEnabled) ?? true
        showHistoryHotkey = try container.decodeIfPresent(HotkeyDescriptor.self, forKey: .showHistoryHotkey) ?? fallback.showHistoryHotkey
        toggleMonitoringHotkey = try container.decodeIfPresent(HotkeyDescriptor.self, forKey: .toggleMonitoringHotkey) ?? fallback.toggleMonitoringHotkey
        windowFrame = try container.decodeIfPresent(String.self, forKey: .windowFrame) ?? ""
        sortMode = try container.decodeIfPresent(String.self, forKey: .sortMode) ?? "LastUsed"
        sortDescending = try container.decodeIfPresent(Bool.self, forKey: .sortDescending) ?? true
        fileHistorySortMode = try container.decodeIfPresent(String.self, forKey: .fileHistorySortMode) ?? "Manual"
        fileHistorySortDescending = try container.decodeIfPresent(Bool.self, forKey: .fileHistorySortDescending) ?? false
        lastSelectedTab = try container.decodeIfPresent(Int.self, forKey: .lastSelectedTab) ?? 0
        linksHistoryEnabled = try container.decodeIfPresent(Bool.self, forKey: .linksHistoryEnabled) ?? false
        richTextHistoryEnabled = try container.decodeIfPresent(Bool.self, forKey: .richTextHistoryEnabled) ?? false
        lastSelectedHistoryTab = try container.decodeIfPresent(String.self, forKey: .lastSelectedHistoryTab) ?? (lastSelectedTab == 1 ? HistoryTabID.files : HistoryTabID.text)
        historyTabOrder = HistoryTabID.normalizeOrder(try container.decodeIfPresent([String].self, forKey: .historyTabOrder))
        groupFilter = try container.decodeIfPresent(String.self, forKey: .groupFilter) ?? "All"
        historyFilterType = (try container.decodeIfPresent(String.self, forKey: .historyFilterType) ?? "Group").caseInsensitiveCompare("Device") == .orderedSame ? "Device" : "Group"
        deviceFilter = try container.decodeIfPresent(String.self, forKey: .deviceFilter) ?? "All"
        confirmDeletions = try container.decodeIfPresent(Bool.self, forKey: .confirmDeletions) ?? true
        runAtStartup = try container.decodeIfPresent(Bool.self, forKey: .runAtStartup) ?? false
        captureClipboardOnStartup = try container.decodeIfPresent(Bool.self, forKey: .captureClipboardOnStartup) ?? false
        rememberDatabasePassword = try container.decodeIfPresent(Bool.self, forKey: .rememberDatabasePassword) ?? false
        autoCopyLatestRemoteText = try container.decodeIfPresent(Bool.self, forKey: .autoCopyLatestRemoteText) ?? false
        pasteAfterEnter = try container.decodeIfPresent(Bool.self, forKey: .pasteAfterEnter) ?? false
        dynamicHistoryMode = try container.decodeIfPresent(Bool.self, forKey: .dynamicHistoryMode) ?? false
        updateCheckFrequency = try container.decodeIfPresent(String.self, forKey: .updateCheckFrequency) ?? "Never"
        installUpdatesSilently = try container.decodeIfPresent(Bool.self, forKey: .installUpdatesSilently) ?? false
        lastUpdateCheckUnixMs = try container.decodeIfPresent(Int64.self, forKey: .lastUpdateCheckUnixMs) ?? 0
        ignoredApplications = try container.decodeIfPresent([String].self, forKey: .ignoredApplications)
            ?? container.decodeIfPresent([String].self, forKey: .ignoredProcesses)
            ?? []
        sensitiveDataMode = SensitiveDataExclusion.normalizeMode(try container.decodeIfPresent(String.self, forKey: .sensitiveDataMode))
        let knownSensitiveIds = Set(SensitiveDataExclusion.builtInPresets.map(\.id))
        sensitiveDataPresetIds = (try container.decodeIfPresent([String].self, forKey: .sensitiveDataPresetIds) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && knownSensitiveIds.contains($0) }
        let legacyQuickCopyHotkey = try container.decodeIfPresent(HotkeyDescriptor.self, forKey: .legacyQuickCopyHotkey)
            ?? HotkeyDescriptor(keyCode: UInt32(kVK_F2), modifiers: [.option, .shift])
        let legacyQuickCopyEntryID = try container.decodeIfPresent(String.self, forKey: .legacyQuickCopyEntryID) ?? ""
        quickCopyHotkeys = try container.decodeIfPresent([String: HotkeyDescriptor].self, forKey: .quickCopyHotkeys) ?? [:]
        quickPasteModes = try container.decodeIfPresent([String: String].self, forKey: .quickPasteModes) ?? [:]
        if quickCopyHotkeys.isEmpty, !legacyQuickCopyEntryID.isEmpty, legacyQuickCopyHotkey.isValid {
            quickCopyHotkeys[legacyQuickCopyEntryID] = legacyQuickCopyHotkey
            quickPasteModes[legacyQuickCopyEntryID] = QuickPasteMode.pasteRestore.rawValue
        }
        quickPasteModes = Dictionary(uniqueKeysWithValues: quickPasteModes.map { key, value in
            (key, QuickPasteMode.normalize(value).rawValue)
        })
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(machineName, forKey: .machineName)
        try container.encode(deviceName, forKey: .deviceName)
        try container.encode(databasePath, forKey: .databasePath)
        try container.encode(storageMode, forKey: .storageMode)
        try container.encode(serverUrl, forKey: .serverUrl)
        try container.encode(serverCaCertPem, forKey: .serverCaCertPem)
        try container.encode(serverCaHost, forKey: .serverCaHost)
        try container.encode(monitoringEnabled, forKey: .monitoringEnabled)
        try container.encode(soundsEnabled, forKey: .soundsEnabled)
        try container.encode(showHistoryHotkey, forKey: .showHistoryHotkey)
        try container.encode(toggleMonitoringHotkey, forKey: .toggleMonitoringHotkey)
        try container.encode(windowFrame, forKey: .windowFrame)
        try container.encode(sortMode, forKey: .sortMode)
        try container.encode(sortDescending, forKey: .sortDescending)
        try container.encode(fileHistorySortMode, forKey: .fileHistorySortMode)
        try container.encode(fileHistorySortDescending, forKey: .fileHistorySortDescending)
        try container.encode(lastSelectedTab, forKey: .lastSelectedTab)
        try container.encode(lastSelectedHistoryTab, forKey: .lastSelectedHistoryTab)
        try container.encode(HistoryTabID.normalizeOrder(historyTabOrder), forKey: .historyTabOrder)
        try container.encode(linksHistoryEnabled, forKey: .linksHistoryEnabled)
        try container.encode(richTextHistoryEnabled, forKey: .richTextHistoryEnabled)
        try container.encode(groupFilter, forKey: .groupFilter)
        try container.encode(historyFilterType, forKey: .historyFilterType)
        try container.encode(deviceFilter, forKey: .deviceFilter)
        try container.encode(confirmDeletions, forKey: .confirmDeletions)
        try container.encode(runAtStartup, forKey: .runAtStartup)
        try container.encode(captureClipboardOnStartup, forKey: .captureClipboardOnStartup)
        try container.encode(rememberDatabasePassword, forKey: .rememberDatabasePassword)
        try container.encode(autoCopyLatestRemoteText, forKey: .autoCopyLatestRemoteText)
        try container.encode(pasteAfterEnter, forKey: .pasteAfterEnter)
        try container.encode(dynamicHistoryMode, forKey: .dynamicHistoryMode)
        try container.encode(updateCheckFrequency, forKey: .updateCheckFrequency)
        try container.encode(installUpdatesSilently, forKey: .installUpdatesSilently)
        try container.encode(lastUpdateCheckUnixMs, forKey: .lastUpdateCheckUnixMs)
        try container.encode(quickCopyHotkeys, forKey: .quickCopyHotkeys)
        try container.encode(quickPasteModes, forKey: .quickPasteModes)
        try container.encode(ignoredApplications, forKey: .ignoredApplications)
        try container.encode(sensitiveDataMode, forKey: .sensitiveDataMode)
        try container.encode(sensitiveDataPresetIds, forKey: .sensitiveDataPresetIds)
    }

    static func defaults(applicationSupport: URL) -> ClipmanSettings {
        let machineName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return ClipmanSettings(
            machineName: machineName,
            deviceName: machineName,
            databasePath: applicationSupport.appendingPathComponent("clipman-history.clipdb").path,
            storageMode: "File",
            serverUrl: "",
            serverToken: "",
            serverCaCertPem: "",
            serverCaHost: "",
            monitoringEnabled: true,
            soundsEnabled: true,
            showHistoryHotkey: HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_Grave), modifiers: [.option, .shift]),
            toggleMonitoringHotkey: HotkeyDescriptor(keyCode: UInt32(kVK_ISO_Section), modifiers: [.option, .shift]),
            windowFrame: "",
            sortMode: "LastUsed",
            sortDescending: true,
            fileHistorySortMode: "Manual",
            fileHistorySortDescending: false,
            lastSelectedTab: 0,
            lastSelectedHistoryTab: HistoryTabID.text,
            historyTabOrder: HistoryTabID.defaultOrder,
            linksHistoryEnabled: false,
            richTextHistoryEnabled: false,
            groupFilter: "All",
            historyFilterType: "Group",
            deviceFilter: "All",
            confirmDeletions: true,
            runAtStartup: false,
            captureClipboardOnStartup: false,
            rememberDatabasePassword: false,
            autoCopyLatestRemoteText: false,
            pasteAfterEnter: false,
            dynamicHistoryMode: false,
            updateCheckFrequency: "Never",
            installUpdatesSilently: false,
            lastUpdateCheckUnixMs: 0,
            quickCopyHotkeys: [:],
            quickPasteModes: [:],
            ignoredApplications: [],
            sensitiveDataMode: SensitiveDataExclusion.modeOff,
            sensitiveDataPresetIds: []
        )
    }

    static func normalizeStorageMode(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Server") == .orderedSame
            ? "Server"
            : "File"
    }
}

enum QuickPasteMode: String, Codable, CaseIterable {
    case pasteRestore = "PasteRestore"
    case pasteKeep = "PasteKeep"
    case copyOnly = "CopyOnly"

    static func normalize(_ value: String?) -> QuickPasteMode {
        guard let value else { return .pasteRestore }
        if value.caseInsensitiveCompare(pasteKeep.rawValue) == .orderedSame { return .pasteKeep }
        if value.caseInsensitiveCompare(copyOnly.rawValue) == .orderedSame { return .copyOnly }
        return .pasteRestore
    }

    var displayText: String {
        switch self {
        case .pasteRestore:
            return "paste and restore clipboard"
        case .pasteKeep:
            return "paste and keep target on clipboard"
        case .copyOnly:
            return "copy to clipboard only"
        }
    }
}
