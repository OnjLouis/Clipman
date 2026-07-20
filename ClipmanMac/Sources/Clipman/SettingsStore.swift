import Foundation
import Carbon
import ClipmanCore

final class SettingsStore {
    let applicationSupportURL: URL
    let pointerURL: URL
    private(set) var loadedSettingsHadRememberDatabasePassword = true
    private let machine: String

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Clipman", isDirectory: true)
        applicationSupportURL = support
        machine = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        pointerURL = support.appendingPathComponent("settings-location.json")
    }

    func load() throws -> ClipmanSettings {
        try FileManager.default.createDirectory(at: applicationSupportURL, withIntermediateDirectories: true)
        resolveSettingsLocationConflicts()

        let pointerFolder = try loadDataFolderPointer()
        let loaded: (settings: ClipmanSettings, url: URL)?
        if let pointerFolder {
            let pointerSettingsURL = settingsURL(in: pointerFolder)
            if FileManager.default.fileExists(atPath: pointerSettingsURL.path) {
                do {
                    loaded = (try loadSettings(from: pointerSettingsURL), pointerSettingsURL)
                } catch {
                    throw SettingsStoreError.unreadableSettings(pointerSettingsURL.path, error)
                }
            } else {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: pointerFolder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw SettingsStoreError.dataFolderUnavailable(pointerFolder.path)
                }

                var migrated = try loadLocalSettings()?.settings ?? ClipmanSettings.defaults(applicationSupport: applicationSupportURL)
                migrated.databasePath = pointerFolder.appendingPathComponent("clipman-history.clipdb").path
                loaded = (migrated, pointerSettingsURL)
            }
        } else {
            loaded = try loadLocalSettings()
        }

        loadedSettingsHadRememberDatabasePassword = loaded.map { settingsFileContainsProperty($0.url, "rememberDatabasePassword") } ?? true
        var settings = loaded?.settings ?? ClipmanSettings.defaults(applicationSupport: applicationSupportURL)
        if let loaded,
           !settingsFileContainsProperty(loaded.url, "lastSelectedHistoryTab") {
            settings.lastSelectedHistoryTab = settings.lastSelectedTab == 1 ? HistoryTabID.files : HistoryTabID.text
        }
        _ = repairInvalidHotkeys(&settings)
        _ = normalize(&settings)
        try save(settings)
        return settings
    }

    func save(_ settings: ClipmanSettings) throws {
        let folder = dataFolder(for: settings)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(settings)
        try data.write(to: settingsURL(in: folder), options: [.atomic])
        try saveDataFolderPointer(folder)
    }

    func settingsURL(for settings: ClipmanSettings) -> URL {
        settingsURL(in: dataFolder(for: settings))
    }

    func dataFolder(for settings: ClipmanSettings) -> URL {
        URL(fileURLWithPath: settings.databasePath).deletingLastPathComponent()
    }

    private func repairInvalidHotkeys(_ settings: inout ClipmanSettings) -> Bool {
        let defaults = ClipmanSettings.defaults(applicationSupport: applicationSupportURL)
        var changed = false
        if !settings.showHistoryHotkey.isValid || settings.showHistoryHotkey.keyCode == UInt32(kVK_ANSI_Backslash) {
            settings.showHistoryHotkey = defaults.showHistoryHotkey
            changed = true
        }
        if !settings.toggleMonitoringHotkey.isValid || settings.toggleMonitoringHotkey == settings.showHistoryHotkey {
            settings.toggleMonitoringHotkey = defaults.toggleMonitoringHotkey
            changed = true
        }
        var seenQuickCopyHotkeys = Set<HotkeyDescriptor>()
        for (entryID, hotkey) in Array(settings.quickCopyHotkeys) {
            if entryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !hotkey.isValid
                || hotkey == settings.showHistoryHotkey
                || hotkey == settings.toggleMonitoringHotkey
                || seenQuickCopyHotkeys.contains(hotkey) {
                settings.quickCopyHotkeys.removeValue(forKey: entryID)
                settings.quickPasteModes.removeValue(forKey: entryID)
                changed = true
            } else {
                seenQuickCopyHotkeys.insert(hotkey)
            }
        }
        for (entryID, mode) in Array(settings.quickPasteModes) {
            let normalized = QuickPasteMode.normalize(mode).rawValue
            if settings.quickCopyHotkeys[entryID] == nil {
                settings.quickPasteModes.removeValue(forKey: entryID)
                changed = true
            } else if normalized != mode {
                settings.quickPasteModes[entryID] = normalized
                changed = true
            }
        }
        if settings.showHistoryHotkey.keyCode == UInt32(kVK_ISO_Section),
           settings.toggleMonitoringHotkey.keyCode == UInt32(kVK_ANSI_Grave) {
            settings.showHistoryHotkey = defaults.showHistoryHotkey
            settings.toggleMonitoringHotkey = defaults.toggleMonitoringHotkey
            changed = true
        }
        return changed
    }

    @discardableResult
    private func normalize(_ settings: inout ClipmanSettings) -> Bool {
        var changed = false
        if settings.machineName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.machineName = machine
            changed = true
        }
        if settings.databasePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.databasePath = applicationSupportURL.appendingPathComponent("clipman-history.clipdb").path
            changed = true
        }
        let normalizedDatabasePath = normalizeDatabasePath(settings.databasePath)
        if normalizedDatabasePath != settings.databasePath {
            settings.databasePath = normalizedDatabasePath
            changed = true
        }
        let normalizedStorageMode = ClipmanSettings.normalizeStorageMode(settings.storageMode)
        if normalizedStorageMode != settings.storageMode {
            settings.storageMode = normalizedStorageMode
            changed = true
        }
        let normalizedServerURL = ServerSettingsSanitizer.cleanURL(settings.serverUrl)
        if normalizedServerURL != settings.serverUrl {
            settings.serverUrl = normalizedServerURL
            changed = true
        }
        let normalizedServerToken = ServerSettingsSanitizer.cleanToken(settings.serverToken)
        if normalizedServerToken != settings.serverToken {
            settings.serverToken = normalizedServerToken
            changed = true
        }
        let normalizedSort = normalizeTextSortMode(settings.sortMode)
        if normalizedSort != settings.sortMode {
            settings.sortMode = normalizedSort
            changed = true
        }
        let normalizedFileSort = normalizeFileSortMode(settings.fileHistorySortMode)
        if normalizedFileSort != settings.fileHistorySortMode {
            settings.fileHistorySortMode = normalizedFileSort
            changed = true
        }
        if settings.lastSelectedTab < 0 || settings.lastSelectedTab > 1 {
            settings.lastSelectedTab = 0
            changed = true
        }
        let normalizedHistoryTab = HistoryTabID.normalize(settings.lastSelectedHistoryTab, linksEnabled: settings.linksHistoryEnabled)
        if normalizedHistoryTab != settings.lastSelectedHistoryTab {
            settings.lastSelectedHistoryTab = normalizedHistoryTab
            changed = true
        }
        let legacySelectedTab = normalizedHistoryTab == HistoryTabID.files ? 1 : 0
        if settings.lastSelectedTab != legacySelectedTab {
            settings.lastSelectedTab = legacySelectedTab
            changed = true
        }
        if settings.groupFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.groupFilter = "All"
            changed = true
        }
        let normalizedIgnored = normalizedIgnoredApplications(settings.ignoredApplications)
        if normalizedIgnored != settings.ignoredApplications {
            settings.ignoredApplications = normalizedIgnored
            changed = true
        }
        return changed
    }

    private func loadSettings(from url: URL) throws -> ClipmanSettings {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ClipmanSettings.self, from: data)
    }

    private func settingsFileContainsProperty(_ url: URL, _ property: String) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object.keys.contains { $0.caseInsensitiveCompare(property) == .orderedSame }
    }

    private func settingsURL(in folder: URL) -> URL {
        folder.appendingPathComponent(machineSettingsFileName())
    }

    private func localSettingsCandidates() -> [URL] {
        var urls: [URL] = []
        urls.append(applicationSupportURL.appendingPathComponent(machineSettingsFileName()))
        urls.append(applicationSupportURL.appendingPathComponent("\(machine)-settings.json"))
        let seen = Set<String>()
        return urls.reduce(into: (items: [URL](), seen: seen)) { state, url in
            guard !state.seen.contains(url.path) else { return }
            state.seen.insert(url.path)
            state.items.append(url)
        }.items
    }

    private func loadLocalSettings() throws -> (settings: ClipmanSettings, url: URL)? {
        var unreadable: (URL, Error)?
        for url in localSettingsCandidates() where FileManager.default.fileExists(atPath: url.path) {
            do {
                return (try loadSettings(from: url), url)
            } catch {
                if unreadable == nil { unreadable = (url, error) }
            }
        }
        if let unreadable {
            throw SettingsStoreError.unreadableSettings(unreadable.0.path, unreadable.1)
        }
        return nil
    }

    private func machineSettingsFileName() -> String {
        "\(safeMachineName(machine))-settings.json"
    }

    private func loadDataFolderPointer() throws -> URL? {
        resolveSettingsLocationConflicts()
        guard FileManager.default.fileExists(atPath: pointerURL.path) else { return nil }
        guard let pointer = loadSettingsLocationPointer(pointerURL) else {
            throw SettingsStoreError.unreadablePointer(pointerURL.path)
        }
        guard
              let path = pointer.folder(for: safeMachineName(machine)),
              !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func saveDataFolderPointer(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: applicationSupportURL, withIntermediateDirectories: true)
        resolveSettingsLocationConflicts()
        var pointer: SettingsLocationPointer
        if FileManager.default.fileExists(atPath: pointerURL.path) {
            guard let existing = loadSettingsLocationPointer(pointerURL) else {
                throw SettingsStoreError.unreadablePointer(pointerURL.path)
            }
            pointer = existing
        } else {
            pointer = SettingsLocationPointer()
        }
        pointer.setFolder(folder.path, for: safeMachineName(machine))
        let data = try JSONSerialization.data(withJSONObject: pointer.jsonObject, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: pointerURL, options: [.atomic])
        deleteSettingsLocationConflicts()
    }

    private func resolveSettingsLocationConflicts() {
        let conflicts = SyncConflictResolver.conflictSiblings(for: pointerURL)
        guard !conflicts.isEmpty else { return }

        var candidates: [(url: URL, folder: URL, modified: Date)] = []
        addSettingsLocationCandidate(pointerURL, to: &candidates)
        for conflict in conflicts {
            addSettingsLocationCandidate(conflict, to: &candidates)
        }

        if let merged = mergeSettingsLocationPointers(candidates) {
            if let data = try? JSONSerialization.data(withJSONObject: merged.jsonObject, options: [.prettyPrinted, .withoutEscapingSlashes]),
               (try? data.write(to: pointerURL, options: [.atomic])) != nil {
                deleteSettingsLocationConflicts()
            }
        }
    }

    private func addSettingsLocationCandidate(_ url: URL, to candidates: inout [(url: URL, folder: URL, modified: Date)]) {
        guard let pointer = loadSettingsLocationPointer(url) else { return }

        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if let folder = pointer.dataFolder, !folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append((url, URL(fileURLWithPath: folder), modified))
        }
        for folder in pointer.clients.values where !folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append((url, URL(fileURLWithPath: folder), modified))
        }
    }

    private func loadSettingsLocationPointer(_ url: URL) -> SettingsLocationPointer? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return SettingsLocationPointer(jsonObject: object)
    }

    private func mergeSettingsLocationPointers(_ candidates: [(url: URL, folder: URL, modified: Date)]) -> SettingsLocationPointer? {
        var merged = SettingsLocationPointer()
        var sawAny = false
        for candidate in candidates.sorted(by: { $0.modified < $1.modified }) {
            if let pointer = loadSettingsLocationPointer(candidate.url) {
                if let dataFolder = pointer.dataFolder,
                   isValidSettingsLocation(dataFolder) {
                    merged.dataFolder = dataFolder
                    sawAny = true
                }
                for (client, folder) in pointer.clients where isValidSettingsLocation(folder) {
                    merged.clients[client] = folder
                    sawAny = true
                }
            }
        }
        return sawAny ? merged : nil
    }

    private func isValidSettingsLocation(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return URL(fileURLWithPath: trimmed).path.hasPrefix("/")
    }

    private func deleteSettingsLocationConflicts() {
        for conflict in SyncConflictResolver.conflictSiblings(for: pointerURL) {
            try? FileManager.default.removeItem(at: conflict)
        }
    }

    private func normalizeDatabasePath(_ value: String) -> String {
        let url = URL(fileURLWithPath: value)
        if url.lastPathComponent.lowercased() == "clipman-history.clipdb" {
            return url.path
        }
        if url.pathExtension.lowercased() == "clipdb" {
            return url.path
        }
        return url.appendingPathComponent("clipman-history.clipdb").path
    }

    private func normalizeTextSortMode(_ sortMode: String) -> String {
        switch sortMode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "ADDED": return "Added"
        case "TEXT": return "Text"
        case "GROUP": return "Group"
        case "MACHINE": return "Machine"
        case "MANUAL": return "Manual"
        default: return "LastUsed"
        }
    }

    private func normalizeFileSortMode(_ sortMode: String) -> String {
        switch sortMode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "TIME": return "Time"
        case "FILES": return "Files"
        case "NAME": return "Name"
        case "OPERATION": return "Operation"
        case "SOURCE": return "Source"
        default: return "Manual"
        }
    }

    private func normalizedIgnoredApplications(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(trimmed)
        }
        return result
    }

    private func safeMachineName(_ value: String) -> String {
        let safe = value
            .map { character in
                character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" } ? character : "-"
            }
        let result = String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
        return result.isEmpty ? "Mac" : result
    }
}

private enum SettingsStoreError: LocalizedError {
    case dataFolderUnavailable(String)
    case unreadablePointer(String)
    case unreadableSettings(String, Error)

    var errorDescription: String? {
        switch self {
        case .dataFolderUnavailable(let path):
            return "Clipman cannot reach the configured data folder:\n\n\(path)\n\nReconnect the drive, cloud service, or network share, then start Clipman again. Clipman did not switch to the default data folder."
        case .unreadablePointer(let path):
            return "Clipman could not read its data-folder pointer:\n\n\(path)\n\nClipman did not switch to the default data folder."
        case .unreadableSettings(let path, let underlying):
            return "Clipman could not read the settings file in the configured data folder:\n\n\(path)\n\n\(underlying.localizedDescription)\n\nClipman did not switch to a different data folder."
        }
    }
}

private struct SettingsLocationPointer {
    var dataFolder: String?
    var clients: [String: String] = [:]

    init() {
        dataFolder = nil
        clients = [:]
    }

    init(jsonObject: [String: Any]) {
        dataFolder = jsonObject["dataFolder"] as? String
        clients = jsonObject["clients"] as? [String: String] ?? [:]
    }

    var jsonObject: [String: Any] {
        var object: [String: Any] = [:]
        if let dataFolder, !dataFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            object["dataFolder"] = dataFolder
        }
        object["clients"] = clients
        return object
    }

    func folder(for machineName: String) -> String? {
        if let match = clients.first(where: { $0.key.caseInsensitiveCompare(machineName) == .orderedSame }) {
            return match.value
        }
        return dataFolder
    }

    mutating func setFolder(_ folder: String, for machineName: String) {
        clients[machineName] = folder
    }
}
