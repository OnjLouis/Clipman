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

    enum CodingKeys: String, CodingKey {
        case machineName, databasePath, monitoringEnabled, showHistoryHotkey, toggleMonitoringHotkey, windowFrame
        case sortMode, sortDescending, fileHistorySortMode, fileHistorySortDescending, lastSelectedTab, groupFilter, runAtStartup
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
        runAtStartup: Bool
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
            runAtStartup: false
        )
    }
}
