import Foundation
import SwiftUI
import UIKit

@MainActor
final class ClipmanAppModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case text = "Text"
        case links = "Links"

        var id: String { rawValue }
    }

    @Published var isUnlocked = false
    @Published var settings = SettingsStore.load()
    @Published var database = ClipDatabase() {
        didSet {
            rebuildLinkCache()
        }
    }
    @Published var selectedSection: Section = .text
    @Published var searchText = ""
    @Published var groupFilter = "All"
    @Published var status = "Ready"
    @Published var showingSettings = false
    @Published var showingClipboardImport = false
    @Published var isRefreshing = false
    @Published private(set) var pendingServerConnection: ServerConnectionDetails?
    @Published private(set) var serverConnectionImportError = ""
    @Published private(set) var serverConnectionImportSequence = 0
    @Published private(set) var isImportingServerConnection = false
    @Published private(set) var linkItems: [LinkExtractor.LinkItem] = []

    private let soundService = SoundService()
    private let historyRepository = MobileHistoryRepository()
    private var revision = ""
    private var unlockTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var refreshInProgress = false
    private var hasPendingLocalChanges = false
    private var storageGeneration = 0
    private var isUnlocking = false
    private var isSceneActive = true
    private var foregroundGeneration = 0
    private var lastRemoteEntryID = ""
    private var pureLinkEntryIDs = Set<String>()
    private var machineName: String {
        let name = settings.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? UIDeviceMachine.name : name
    }

    var groups: [String] {
        let values = Set(database.Entries.map { $0.Group.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        return ["All"] + values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var visibleEntries: [ClipEntry] {
        var entries = database.Entries
        if selectedSection == .text {
            entries = entries.filter { !pureLinkEntryIDs.contains($0.Id) }
        }
        if groupFilter != "All" {
            entries = entries.filter { $0.Group.caseInsensitiveCompare(groupFilter) == .orderedSame }
        }
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            entries = entries.filter {
                $0.Text.localizedCaseInsensitiveContains(query)
                || $0.Name.localizedCaseInsensitiveContains(query)
                || $0.Group.localizedCaseInsensitiveContains(query)
            }
        }
        return entries.sorted {
            if $0.Pinned != $1.Pinned { return $0.Pinned && !$1.Pinned }
            let leftOrder = $0.ManualOrder <= 0 ? Int64.max : $0.ManualOrder
            let rightOrder = $1.ManualOrder <= 0 ? Int64.max : $1.ManualOrder
            if leftOrder == rightOrder { return $0.CreatedUnixMs < $1.CreatedUnixMs }
            return leftOrder < rightOrder
        }
    }

    var visibleLinkItems: [LinkExtractor.LinkItem] {
        var items = linkItems
        if groupFilter != "All" {
            items = items.filter { $0.entry.Group.caseInsensitiveCompare(groupFilter) == .orderedSame }
        }
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            items = items.filter {
                $0.url.absoluteString.localizedCaseInsensitiveContains(query)
                || $0.entry.Text.localizedCaseInsensitiveContains(query)
                || $0.entry.Name.localizedCaseInsensitiveContains(query)
                || $0.entry.Group.localizedCaseInsensitiveContains(query)
            }
        }
        return items
    }

    func announceStatus(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: trimmed)
    }

    func switchSection(_ section: Section) {
        guard settings.linksEnabled, selectedSection != section else { return }
        selectedSection = section
        status = "\(section.rawValue) clipboard history."
    }

    func unlock() {
        guard !isUnlocked, !isUnlocking else { return }
        isUnlocking = true
        let generation = foregroundGeneration
        unlockTask?.cancel()
        unlockTask = Task { [weak self] in
            guard let self else { return }
            let authenticated = await AuthenticationService.unlock()
            isUnlocking = false
            guard !Task.isCancelled, generation == foregroundGeneration, isSceneActive else {
                if isSceneActive {
                    unlock()
                }
                return
            }
            if authenticated {
                isUnlocked = true
                let loaded = await refresh(showStatus: true)
                guard !Task.isCancelled, generation == foregroundGeneration, isUnlocked else { return }
                if isImportingServerConnection {
                    // The import completion opens Settings once the file has finished loading.
                } else if pendingServerConnection != nil || !serverConnectionImportError.isEmpty {
                    showingSettings = true
                } else if loaded, settings.addClipboardOnLaunch, UIPasteboard.general.hasStrings {
                    showingClipboardImport = true
                }
                startPolling()
            } else {
                status = "Authentication cancelled."
            }
        }
    }

    func openServerConnectionFile(_ url: URL) {
        isImportingServerConnection = true
        showingClipboardImport = false
        Task { [weak self] in
            guard let self else { return }
            let result = await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard fileSize <= 65_536 else { throw ConnectionConfigError.fileTooLarge }
                    return Result<ServerConnectionDetails, ConnectionConfigError>.success(
                        try ServerSettingsSanitizer.parseConnectionConfig(Data(contentsOf: url))
                    )
                } catch let error as ConnectionConfigError {
                    return .failure(error)
                } catch {
                    return .failure(.invalidFile)
                }
            }.value
            switch result {
            case .success(let details):
                pendingServerConnection = details
                serverConnectionImportError = ""
            case .failure(let error):
                pendingServerConnection = nil
                serverConnectionImportError = error.localizedDescription
            }
            isImportingServerConnection = false
            serverConnectionImportSequence += 1
            if isUnlocked {
                showingClipboardImport = false
                showingSettings = true
            }
        }
    }

    func consumeServerConnectionImport() -> (ServerConnectionDetails?, String) {
        let result = (pendingServerConnection, serverConnectionImportError)
        pendingServerConnection = nil
        serverConnectionImportError = ""
        return result
    }

    func sceneBecameActive() {
        isSceneActive = true
        if !isUnlocked {
            unlock()
        }
    }

    func sceneMovedToBackground() {
        isSceneActive = false
        foregroundGeneration += 1
        unlockTask?.cancel()
        unlockTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        showingSettings = false
        showingClipboardImport = false
        isUnlocked = false
        status = "Clipman is locked."
    }

    func saveSettings(_ newSettings: ClipmanSettings) {
        storageGeneration += 1
        refreshTask?.cancel()
        uploadTask?.cancel()
        settings = newSettings
        if !settings.linksEnabled && selectedSection == .links {
            selectedSection = .text
        }
        SettingsStore.save(newSettings)
        revision = ""
        hasPendingLocalChanges = newSettings.storageMode == .server
        let generation = storageGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                try await historyRepository.saveLocal(database, password: newSettings.historyPassword)
            } catch {
                status = "Could not save local history: \(error.localizedDescription)"
                return
            }
            guard generation == storageGeneration else { return }
            startPolling()
            _ = await refresh(showStatus: true)
        }
    }

    func startPolling() {
        refreshTask?.cancel()
        guard settings.storageMode == .server, settings.refreshIntervalSeconds >= 2 else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(2, self?.settings.refreshIntervalSeconds ?? 3) * 1_000_000_000))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await self?.refresh(showStatus: false)
            }
        }
    }

    @discardableResult
    func refresh(showStatus: Bool) async -> Bool {
        guard !refreshInProgress else { return false }
        let generation = storageGeneration
        let settingsSnapshot = settings
        if settingsSnapshot.storageMode == .local {
            refreshInProgress = true
            if showStatus { isRefreshing = true }
            defer {
                refreshInProgress = false
                if showStatus { isRefreshing = false }
            }
            do {
                if let local = try await historyRepository.loadLocal(password: settingsSnapshot.historyPassword) {
                    guard generation == storageGeneration else { return false }
                    if !SyncConflictResolver.hasSameContent(local, database) {
                        database = local
                    }
                } else {
                    try await historyRepository.saveLocal(database, password: settingsSnapshot.historyPassword)
                    guard generation == storageGeneration else { return false }
                }
                revision = ""
                hasPendingLocalChanges = false
                if showStatus { status = "Local history loaded. \(loadedStatusText())" }
                return true
            } catch {
                guard generation == storageGeneration else { return false }
                status = "Could not load local history: \(error.localizedDescription)"
                return false
            }
        }
        let client = ServerStorageClient(settings: settingsSnapshot)
        guard client.isConfigured else {
            status = "Open Settings to configure Clipman Server."
            showingSettings = true
            return false
        }
        refreshInProgress = true
        if showStatus { isRefreshing = true }
        defer {
            refreshInProgress = false
            if showStatus { isRefreshing = false }
        }
        do {
            if !showStatus && !revision.isEmpty && !hasPendingLocalChanges {
                let metadata = try await client.metadata()
                if metadata.revision == revision {
                    return true
                }
            }
            let previousNewest = newestRemoteEntry(in: database)
            let sync = try await historyRepository.synchronize(settings: settingsSnapshot, current: database)
            guard generation == storageGeneration else { return false }
            let merged = sync.database
            if merged != database {
                database = merged
            }
            revision = sync.revision
            hasPendingLocalChanges = false
            if !showStatus, previousNewest != nil, let newest = newestRemoteEntry(in: merged), newest.Id != previousNewest?.Id, newest.Id != lastRemoteEntryID {
                if settings.autoCopyRemote {
                    UIPasteboard.general.string = newest.Text
                }
                lastRemoteEntryID = newest.Id
                let source = newest.SourceMachine.trimmingCharacters(in: .whitespacesAndNewlines)
                status = source.isEmpty ? "Clipboard updated by another machine." : "Clipboard updated by \(source)."
                soundService.play("remote", soundsEnabled: settings.soundsEnabled, hapticsEnabled: settings.hapticsEnabled)
            }
            if showStatus {
                status = loadedStatusText()
            }
            return true
        } catch {
            guard generation == storageGeneration else { return false }
            revision = ""
            do {
                if let cached = try await historyRepository.loadLocal(password: settingsSnapshot.historyPassword) {
                    guard generation == storageGeneration else { return false }
                    if !SyncConflictResolver.hasSameContent(cached, database) {
                        database = cached
                    }
                    status = "Using local history; server sync is pending: \(error.localizedDescription)"
                    return true
                }
            } catch {
                guard generation == storageGeneration else { return false }
                status = "Could not load local history: \(error.localizedDescription)"
                return false
            }
            status = error.localizedDescription
            return false
        }
    }

    func addPastedClipboardText(_ pastedText: String?) {
        showingClipboardImport = false
        guard let text = pastedText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            status = "Clipboard does not contain text."
            soundService.play("skip", soundsEnabled: settings.soundsEnabled, hapticsEnabled: settings.hapticsEnabled)
            return
        }
        let alreadyExists = database.Entries.contains { $0.Text == text }
        database = SyncConflictResolver.addText(database: database, text: text, machineName: machineName)
        queueUpload(successMessage: alreadyExists ? "Clipboard text already exists in history." : "Clipboard text added.")
    }

    func cancelClipboardImport() {
        showingClipboardImport = false
        status = "Clipboard paste cancelled."
    }

    func copy(_ entry: ClipEntry) {
        UIPasteboard.general.string = entry.Text
        database = markUsed(entry)
        soundService.play("copy", soundsEnabled: settings.soundsEnabled, hapticsEnabled: settings.hapticsEnabled)
        status = "Copied to clipboard."
        queueUpload(successMessage: nil)
    }

    func copyText(_ text: String) {
        UIPasteboard.general.string = text
        soundService.play("copy", soundsEnabled: settings.soundsEnabled, hapticsEnabled: settings.hapticsEnabled)
        status = "Copied to clipboard."
    }

    func togglePinned(_ entry: ClipEntry) {
        database = SyncConflictResolver.togglePinned(database: database, entryID: entry.Id)
        queueUpload(successMessage: entry.Pinned ? "Entry unpinned." : "Entry pinned.")
    }

    func delete(_ entry: ClipEntry) {
        database = SyncConflictResolver.deleteEntry(database: database, entryID: entry.Id, machineName: machineName)
        queueUpload(successMessage: "Entry deleted.")
    }

    func update(_ entry: ClipEntry) {
        database = SyncConflictResolver.updateEntry(database: database, entry: entry, machineName: machineName)
        queueUpload(successMessage: "Entry updated.")
    }

    private func queueUpload(successMessage: String?) {
        uploadTask?.cancel()
        let snapshot = database
        let generation = storageGeneration
        let settingsSnapshot = settings
        hasPendingLocalChanges = settings.storageMode == .server
        uploadTask = Task { [weak self] in
            await self?.persistAndSynchronize(snapshot, settings: settingsSnapshot, generation: generation, successMessage: successMessage)
        }
    }

    private func persistAndSynchronize(_ snapshot: ClipDatabase, settings settingsSnapshot: ClipmanSettings, generation: Int, successMessage: String?) async {
        do {
            try await historyRepository.saveLocal(snapshot, password: settingsSnapshot.historyPassword)
            try Task.checkCancellation()
            guard generation == storageGeneration else { return }
            if settingsSnapshot.storageMode == .local {
                hasPendingLocalChanges = false
                if let successMessage { status = "\(successMessage) Saved in local history." }
                return
            }
            let sync = try await historyRepository.synchronize(settings: settingsSnapshot, current: snapshot)
            try Task.checkCancellation()
            guard generation == storageGeneration else { return }
            revision = sync.revision
            hasPendingLocalChanges = false
            if !SyncConflictResolver.hasSameContent(sync.database, database) {
                database = sync.database
            }
            if let successMessage { status = successMessage }
        } catch is CancellationError {
            return
        } catch {
            hasPendingLocalChanges = settingsSnapshot.storageMode == .server
            status = settingsSnapshot.storageMode == .server
                ? "Saved locally; server sync is pending: \(error.localizedDescription)"
                : "Could not save local history: \(error.localizedDescription)"
            soundService.play("skip", soundsEnabled: settings.soundsEnabled, hapticsEnabled: settings.hapticsEnabled)
        }
    }

    private func markUsed(_ entry: ClipEntry) -> ClipDatabase {
        var updated = entry
        updated.LastUsedUnixMs = TimeUtil.nowUnixMs()
        updated.SourceMachine = machineName
        return SyncConflictResolver.updateEntry(database: database, entry: updated, machineName: machineName)
    }

    private func newestRemoteEntry(in database: ClipDatabase) -> ClipEntry? {
        database.Entries
            .filter { !$0.Text.isEmpty && $0.SourceMachine.caseInsensitiveCompare(machineName) != .orderedSame }
            .max {
                if $0.CreatedUnixMs == $1.CreatedUnixMs { return $0.Id < $1.Id }
                return $0.CreatedUnixMs < $1.CreatedUnixMs
            }
    }

    private func rebuildLinkCache() {
        var items: [LinkExtractor.LinkItem] = []
        var pureIDs = Set<String>()
        for entry in database.Entries {
            let links = LinkExtractor.links(in: entry.Text)
            for (index, url) in links.enumerated() {
                items.append(LinkExtractor.LinkItem(id: "\(entry.Id)-link-\(index)", url: url, entry: entry))
            }
            if LinkExtractor.isPureLinkEntry(entry) {
                pureIDs.insert(entry.Id)
            }
        }
        linkItems = items
        pureLinkEntryIDs = pureIDs
    }

    private func loadedStatusText() -> String {
        let total = database.Entries.count
        let links = pureLinkEntryIDs.count
        let text = max(0, total - links)
        return "Loaded \(total) clipboard entries: \(text) text, \(links) links."
    }
}
