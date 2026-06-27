import Foundation
import Carbon

struct ClipmanSettings: Codable, Equatable {
    var machineName: String
    var databasePath: String
    var monitoringEnabled: Bool
    var showHistoryHotkey: HotkeyDescriptor
    var toggleMonitoringHotkey: HotkeyDescriptor
    var windowFrame: String
    var sortMode: String
    var sortDescending: Bool
    var fileHistorySortMode: String
    var fileHistorySortDescending: Bool
    var lastSelectedTab: Int
    var groupFilter: String
    var runAtStartup: Bool
    var rememberDatabasePassword: Bool
    var autoCopyLatestRemoteText: Bool
    var updateCheckFrequency: String
    var installUpdatesSilently: Bool
    var lastUpdateCheckUnixMs: Int64
    var quickCopyHotkeys: [String: HotkeyDescriptor]
    var ignoredApplications: [String]

    enum CodingKeys: String, CodingKey {
        case machineName, databasePath, monitoringEnabled, showHistoryHotkey, toggleMonitoringHotkey, windowFrame
        case sortMode, sortDescending, fileHistorySortMode, fileHistorySortDescending, lastSelectedTab, groupFilter, runAtStartup
        case rememberDatabasePassword
        case autoCopyLatestRemoteText, updateCheckFrequency, installUpdatesSilently, lastUpdateCheckUnixMs, quickCopyHotkeys
        case ignoredApplications
        case ignoredProcesses = "IgnoredProcesses"
        case legacyQuickCopyHotkey = "quickCopyHotkey"
        case legacyQuickCopyEntryID = "quickCopyEntryID"
    }

    init(
        machineName: String,
        databasePath: String,
        monitoringEnabled: Bool,
        showHistoryHotkey: HotkeyDescriptor,
        toggleMonitoringHotkey: HotkeyDescriptor,
        windowFrame: String,
        sortMode: String,
        sortDescending: Bool,
        fileHistorySortMode: String,
        fileHistorySortDescending: Bool,
        lastSelectedTab: Int,
        groupFilter: String,
        runAtStartup: Bool,
        rememberDatabasePassword: Bool,
        autoCopyLatestRemoteText: Bool,
        updateCheckFrequency: String,
        installUpdatesSilently: Bool,
        lastUpdateCheckUnixMs: Int64,
        quickCopyHotkeys: [String: HotkeyDescriptor],
        ignoredApplications: [String]
    ) {
        self.machineName = machineName
        self.databasePath = databasePath
        self.monitoringEnabled = monitoringEnabled
        self.showHistoryHotkey = showHistoryHotkey
        self.toggleMonitoringHotkey = toggleMonitoringHotkey
        self.windowFrame = windowFrame
        self.sortMode = sortMode
        self.sortDescending = sortDescending
        self.fileHistorySortMode = fileHistorySortMode
        self.fileHistorySortDescending = fileHistorySortDescending
        self.lastSelectedTab = lastSelectedTab
        self.groupFilter = groupFilter
        self.runAtStartup = runAtStartup
        self.rememberDatabasePassword = rememberDatabasePassword
        self.autoCopyLatestRemoteText = autoCopyLatestRemoteText
        self.updateCheckFrequency = updateCheckFrequency
        self.installUpdatesSilently = installUpdatesSilently
        self.lastUpdateCheckUnixMs = lastUpdateCheckUnixMs
        self.quickCopyHotkeys = quickCopyHotkeys
        self.ignoredApplications = ignoredApplications
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ClipmanSettings.defaults(applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Clipman", isDirectory: true))
        machineName = try container.decodeIfPresent(String.self, forKey: .machineName) ?? fallback.machineName
        databasePath = try container.decodeIfPresent(String.self, forKey: .databasePath) ?? fallback.databasePath
        monitoringEnabled = try container.decodeIfPresent(Bool.self, forKey: .monitoringEnabled) ?? fallback.monitoringEnabled
        showHistoryHotkey = try container.decodeIfPresent(HotkeyDescriptor.self, forKey: .showHistoryHotkey) ?? fallback.showHistoryHotkey
        toggleMonitoringHotkey = try container.decodeIfPresent(HotkeyDescriptor.self, forKey: .toggleMonitoringHotkey) ?? fallback.toggleMonitoringHotkey
        windowFrame = try container.decodeIfPresent(String.self, forKey: .windowFrame) ?? ""
        sortMode = try container.decodeIfPresent(String.self, forKey: .sortMode) ?? "LastUsed"
        sortDescending = try container.decodeIfPresent(Bool.self, forKey: .sortDescending) ?? true
        fileHistorySortMode = try container.decodeIfPresent(String.self, forKey: .fileHistorySortMode) ?? "Manual"
        fileHistorySortDescending = try container.decodeIfPresent(Bool.self, forKey: .fileHistorySortDescending) ?? false
        lastSelectedTab = try container.decodeIfPresent(Int.self, forKey: .lastSelectedTab) ?? 0
        groupFilter = try container.decodeIfPresent(String.self, forKey: .groupFilter) ?? "All"
        runAtStartup = try container.decodeIfPresent(Bool.self, forKey: .runAtStartup) ?? false
        rememberDatabasePassword = try container.decodeIfPresent(Bool.self, forKey: .rememberDatabasePassword) ?? false
        autoCopyLatestRemoteText = try container.decodeIfPresent(Bool.self, forKey: .autoCopyLatestRemoteText) ?? false
        updateCheckFrequency = try container.decodeIfPresent(String.self, forKey: .updateCheckFrequency) ?? "Never"
        installUpdatesSilently = try container.decodeIfPresent(Bool.self, forKey: .installUpdatesSilently) ?? false
        lastUpdateCheckUnixMs = try container.decodeIfPresent(Int64.self, forKey: .lastUpdateCheckUnixMs) ?? 0
        ignoredApplications = try container.decodeIfPresent([String].self, forKey: .ignoredApplications)
            ?? container.decodeIfPresent([String].self, forKey: .ignoredProcesses)
            ?? []
        let legacyQuickCopyHotkey = try container.decodeIfPresent(HotkeyDescriptor.self, forKey: .legacyQuickCopyHotkey)
            ?? HotkeyDescriptor(keyCode: UInt32(kVK_F2), modifiers: [.option, .shift])
        let legacyQuickCopyEntryID = try container.decodeIfPresent(String.self, forKey: .legacyQuickCopyEntryID) ?? ""
        quickCopyHotkeys = try container.decodeIfPresent([String: HotkeyDescriptor].self, forKey: .quickCopyHotkeys) ?? [:]
        if quickCopyHotkeys.isEmpty, !legacyQuickCopyEntryID.isEmpty, legacyQuickCopyHotkey.isValid {
            quickCopyHotkeys[legacyQuickCopyEntryID] = legacyQuickCopyHotkey
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(machineName, forKey: .machineName)
        try container.encode(databasePath, forKey: .databasePath)
        try container.encode(monitoringEnabled, forKey: .monitoringEnabled)
        try container.encode(showHistoryHotkey, forKey: .showHistoryHotkey)
        try container.encode(toggleMonitoringHotkey, forKey: .toggleMonitoringHotkey)
        try container.encode(windowFrame, forKey: .windowFrame)
        try container.encode(sortMode, forKey: .sortMode)
        try container.encode(sortDescending, forKey: .sortDescending)
        try container.encode(fileHistorySortMode, forKey: .fileHistorySortMode)
        try container.encode(fileHistorySortDescending, forKey: .fileHistorySortDescending)
        try container.encode(lastSelectedTab, forKey: .lastSelectedTab)
        try container.encode(groupFilter, forKey: .groupFilter)
        try container.encode(runAtStartup, forKey: .runAtStartup)
        try container.encode(rememberDatabasePassword, forKey: .rememberDatabasePassword)
        try container.encode(autoCopyLatestRemoteText, forKey: .autoCopyLatestRemoteText)
        try container.encode(updateCheckFrequency, forKey: .updateCheckFrequency)
        try container.encode(installUpdatesSilently, forKey: .installUpdatesSilently)
        try container.encode(lastUpdateCheckUnixMs, forKey: .lastUpdateCheckUnixMs)
        try container.encode(quickCopyHotkeys, forKey: .quickCopyHotkeys)
        try container.encode(ignoredApplications, forKey: .ignoredApplications)
    }

    static func defaults(applicationSupport: URL) -> ClipmanSettings {
        ClipmanSettings(
            machineName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            databasePath: applicationSupport.appendingPathComponent("clipman-history.clipdb").path,
            monitoringEnabled: true,
            showHistoryHotkey: HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_Grave), modifiers: [.option, .shift]),
            toggleMonitoringHotkey: HotkeyDescriptor(keyCode: UInt32(kVK_ISO_Section), modifiers: [.option, .shift]),
            windowFrame: "",
            sortMode: "LastUsed",
            sortDescending: true,
            fileHistorySortMode: "Manual",
            fileHistorySortDescending: false,
            lastSelectedTab: 0,
            groupFilter: "All",
            runAtStartup: false,
            rememberDatabasePassword: false,
            autoCopyLatestRemoteText: false,
            updateCheckFrequency: "Never",
            installUpdatesSilently: false,
            lastUpdateCheckUnixMs: 0,
            quickCopyHotkeys: [:],
            ignoredApplications: []
        )
    }
}
