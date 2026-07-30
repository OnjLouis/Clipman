import Foundation
import SwiftUI
import UIKit

@MainActor
final class ClipmanAppModel: ObservableObject {
    struct HistoryFilter: Hashable, Identifiable {
        enum Kind: String { case all, group, device }
        let kind: Kind
        let value: String
        var id: String { kind.rawValue + ":" + value }
        var label: String {
            switch kind {
            case .all: return "All"
            case .group: return "Group: \(value)"
            case .device: return "Device: \(value)"
            }
        }
        static let all = HistoryFilter(kind: .all, value: "")
    }
    enum Section: String, CaseIterable, Identifiable {
        case text = "Text"
        case richText = "Rich Text"
        case links = "Links"

        var id: String { rawValue }
    }

    @Published var isUnlocked: Bool
    @Published var settings: ClipmanSettings
    @Published var database = ClipDatabase() {
        didSet {
            rebuildLinkCache()
        }
    }
    @Published var selectedSection: Section = .text
    @Published var searchText = ""
    @Published var historyFilter = HistoryFilter.all
    @Published var status = "Ready."
    @Published var showingSettings = false
    @Published var showingClipboardImport = false
    @Published var isRefreshing = false
    @Published private(set) var pendingServerConnection: ServerConnectionDetails?
    @Published private(set) var serverConnectionImportError = ""
    @Published private(set) var serverConnectionImportSequence = 0
    @Published private(set) var isImportingServerConnection = false
    @Published private(set) var linkItems: [LinkExtractor.LinkItem] = []

    private let soundService = SoundService()
    private let historyRepository = MobileHistoryRepository.shared
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
    private var pollingFailureCount = 0
    private var steadyStatus = "Ready."
    private var transientStatusActive = false
    private var statusResetTask: Task<Void, Never>?
    private let pollingIntervalNanoseconds: UInt64 = 15_000_000_000
    private var skipNextSettingsClosedRefresh = false
    private var pureLinkEntryIDs = Set<String>()
    private var machineName: String {
        let name = settings.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? UIDeviceMachine.name : name
    }

    init() {
        let loaded = SettingsStore.load()
        settings = loaded
        // Startup always flows through unlock(), which also loads history and starts polling.
        // When authentication is disabled, unlock() completes without showing a prompt.
        isUnlocked = false
    }

    var groups: [String] {
        canonicalLabels { $0.Group }
    }

    var devices: [String] {
        canonicalLabels { $0.SourceMachine }
    }

    private func canonicalLabels(_ selector: (ClipEntry) -> String) -> [String] {
        let candidates = database.Entries.compactMap { entry -> (String, ClipEntry)? in
            let label = selector(entry).trimmingCharacters(in: .whitespacesAndNewlines)
            return label.isEmpty ? nil : (label, entry)
        }
        let clusters = Dictionary(grouping: candidates) { $0.0.lowercased() }
        return clusters.values.compactMap { cluster in
            Dictionary(grouping: cluster) { $0.0 }.values
                .map { spelling in
                    (
                        label: spelling[0].0,
                        count: spelling.count,
                        latest: spelling.map { max($0.1.ModifiedUnixMs, $0.1.LastUsedUnixMs, $0.1.CreatedUnixMs) }.max() ?? 0
                    )
                }
                .sorted {
                    if $0.count != $1.count { return $0.count > $1.count }
                    if $0.latest != $1.latest { return $0.latest > $1.latest }
                    return $0.label < $1.label
                }
                .first?.label
        }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var visibleSections: [Section] {
        var sections: [Section] = [.text]
        if settings.richTextEnabled { sections.append(.richText) }
        if settings.linksEnabled { sections.append(.links) }
        return sections
    }

    var visibleEntries: [ClipEntry] {
        visibleEntries(in: selectedSection)
    }

    func visibleEntries(in section: Section) -> [ClipEntry] {
        var entries = database.Entries
        switch section {
        case .text:
            entries = entries.filter {
                (!settings.richTextEnabled || $0.RichText == nil) && !pureLinkEntryIDs.contains($0.Id)
            }
        case .richText:
            entries = settings.richTextEnabled ? entries.filter { $0.RichText != nil } : []
        case .links:
            entries = []
        }
        entries = entries.filter(matchesHistoryFilter)
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
        visibleLinkItems(in: selectedSection)
    }

    func visibleLinkItems(in section: Section) -> [LinkExtractor.LinkItem] {
        guard section == .links else { return [] }
        var items = linkItems
        if settings.richTextEnabled {
            items = items.filter { $0.entry.RichText == nil }
        }
        items = items.filter { matchesHistoryFilter($0.entry) }
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

    private func matchesHistoryFilter(_ entry: ClipEntry) -> Bool {
        switch historyFilter.kind {
        case .all:
            return true
        case .group:
            return entry.Group.caseInsensitiveCompare(historyFilter.value) == .orderedSame
        case .device:
            return entry.SourceMachine.caseInsensitiveCompare(historyFilter.value) == .orderedSame
        }
    }

    func announceStatus(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, UIAccessibility.isVoiceOverRunning else { return }
        let queued = NSAttributedString(
            string: trimmed,
            attributes: [.accessibilitySpeechQueueAnnouncement: true]
        )
        UIAccessibility.post(notification: .announcement, argument: queued)
    }

    private func setTransientStatus(_ message: String) {
        statusResetTask?.cancel()
        transientStatusActive = true
        status = message
        statusResetTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            transientStatusActive = false
            status = steadyStatus
            statusResetTask = nil
        }
    }

    private func setSteadyStatus(_ message: String, revealImmediately: Bool = true) {
        steadyStatus = message
        if revealImmediately || !transientStatusActive {
            statusResetTask?.cancel()
            statusResetTask = nil
            transientStatusActive = false
            status = message
        }
    }

    func switchSection(_ section: Section) {
        guard visibleSections.contains(section), selectedSection != section else { return }
        selectedSection = section
        let page = visibleSections.firstIndex(of: section).map { $0 + 1 } ?? 1
        setTransientStatus("\(section.rawValue) clipboard history. Page \(page) of \(visibleSections.count).")
    }

    func switchToAdjacentSection(_ offset: Int) {
        let sections = visibleSections
        guard let current = sections.firstIndex(of: selectedSection) else {
            switchSection(.text)
            return
        }
        let target = current + offset
        guard sections.indices.contains(target) else { return }
        switchSection(sections[target])
    }

    var nextSection: Section {
        let sections = visibleSections
        guard let current = sections.firstIndex(of: selectedSection) else { return .text }
        return sections[(current + 1) % sections.count]
    }

    func unlock() {
        guard !isUnlocked, !isUnlocking else { return }
        isUnlocking = true
        let generation = foregroundGeneration
        unlockTask?.cancel()
        unlockTask = Task { [weak self] in
            guard let self else { return }
            let authenticated: Bool
            if settings.requireAuthentication {
                authenticated = await AuthenticationService.unlock()
            } else {
                authenticated = true
            }
            guard !Task.isCancelled, generation == foregroundGeneration, isSceneActive else {
                isUnlocking = false
                if isSceneActive {
                    unlock()
                }
                return
            }
            if authenticated {
                let cacheLoaded = await loadCachedHistory()
                guard !Task.isCancelled, generation == foregroundGeneration, isSceneActive else {
                    isUnlocking = false
                    return
                }
                isUnlocking = false
                isUnlocked = true
                guard cacheLoaded else {
                    showingSettings = true
                    return
                }
                let hasQuickAction = ClipmanQuickActionCenter.shared.pendingAction != nil
                var shouldRefreshServer = settings.storageMode == .server && !hasQuickAction
                if hasQuickAction {
                    processPendingQuickAction()
                } else if isImportingServerConnection {
                    // The import completion opens Settings once the file has finished loading.
                    shouldRefreshServer = false
                } else if pendingServerConnection != nil || !serverConnectionImportError.isEmpty {
                    showingSettings = true
                    shouldRefreshServer = false
                } else if settings.addClipboardOnLaunch {
                    requestClipboardImport(announceUnavailable: false)
                }
                startPolling()
                if shouldRefreshServer {
                    _ = await refresh(showStatus: false, localCacheIsCurrent: true)
                }
            } else {
                isUnlocking = false
                status = "Authentication cancelled."
            }
        }
    }

    private func loadCachedHistory() async -> Bool {
        let generation = storageGeneration
        let password = settings.historyPassword
        do {
            if let cached = try await historyRepository.loadLocal(password: password) {
                guard generation == storageGeneration else { return false }
                if !SyncConflictResolver.hasSameContent(cached, database) {
                    database = cached
                }
                if settings.storageMode == .server {
                    status = "Cached history loaded; refreshing Clipman Server."
                } else {
                    setSteadyStatus("Ready. Using local history.")
                }
            } else if settings.storageMode == .local {
                _ = try await historyRepository.saveLocal(
                    database,
                    password: password,
                    backupSettings: settings
                )
                guard generation == storageGeneration else { return false }
                setSteadyStatus("Ready. Using local history.")
            } else {
                _ = try await historyRepository.saveLocal(
                    database,
                    password: password,
                    backupSettings: nil
                )
                guard generation == storageGeneration else { return false }
                status = "Connecting to Clipman Server."
            }
            return true
        } catch {
            guard generation == storageGeneration else { return false }
            setSteadyStatus("Could not load local history: \(error.localizedDescription)")
            soundService.play("skip", soundsEnabled: settings.soundsEnabled, hapticsEnabled: settings.hapticsEnabled)
            return false
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
        if isUnlocked {
            processPendingQuickAction()
        } else {
            unlock()
        }
    }

    func processPendingQuickAction() {
        guard isUnlocked, let action = ClipmanQuickActionCenter.shared.consume() else { return }
        showingSettings = false
        showingClipboardImport = false
        switch action {
        case .addClipboard:
            requestClipboardImport()
        case .copyLatest:
            guard let latest = database.Entries
                .filter({ !$0.Text.isEmpty })
                .max(by: {
                    if $0.CreatedUnixMs == $1.CreatedUnixMs { return $0.Id < $1.Id }
                    return $0.CreatedUnixMs < $1.CreatedUnixMs
                }) else {
                setTransientStatus("Clipman history is empty.")
                soundService.play("skip", soundsEnabled: settings.soundsEnabled, hapticsEnabled: settings.hapticsEnabled)
                return
            }
            copy(latest)
        }
    }

    func shortcutCompleted(_ message: String) {
        setTransientStatus(message)
        guard isSceneActive, isUnlocked else { return }
        Task { [weak self] in
            _ = await self?.refresh(showStatus: false)
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
        statusResetTask?.cancel()
        statusResetTask = nil
        transientStatusActive = false
        status = "Clipman is locked."
    }

    func settingsClosed() {
        if skipNextSettingsClosedRefresh {
            skipNextSettingsClosedRefresh = false
            return
        }
        guard isSceneActive, isUnlocked, settings.storageMode == .server else { return }
        Task { [weak self] in
            await self?.refresh(showStatus: false)
        }
    }

    func saveSettings(_ newSettings: ClipmanSettings) {
        skipNextSettingsClosedRefresh = true
        storageGeneration += 1
        refreshTask?.cancel()
        uploadTask?.cancel()
        settings = newSettings
        if !newSettings.requireAuthentication {
            isUnlocked = true
        }
        if !visibleSections.contains(selectedSection) {
            selectedSection = .text
        }
        SettingsStore.save(newSettings)
        revision = ""
        hasPendingLocalChanges = newSettings.storageMode == .server
        let generation = storageGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let backupError = try await historyRepository.saveLocal(
                    database,
                    password: newSettings.historyPassword,
                    backupSettings: newSettings
                )
                guard generation == storageGeneration else { return }
                startPolling()
                _ = await refresh(showStatus: true)
                if let backupError {
                    status = "Settings saved, but the history backup could not be updated: \(backupError)"
                }
            } catch {
                status = "Could not save local history: \(error.localizedDescription)"
                return
            }
        }
    }

    func startPolling() {
        refreshTask?.cancel()
        guard settings.storageMode == .server else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let delayNanoseconds = min(
                    60_000_000_000,
                    pollingIntervalNanoseconds * UInt64(1 << min(pollingFailureCount, 4))
                )
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                guard isSceneActive, isUnlocked, !showingSettings else { continue }
                await refresh(showStatus: false)
            }
        }
    }

    @discardableResult
    func refresh(showStatus: Bool, localCacheIsCurrent: Bool = false) async -> Bool {
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
                var localBackupError: String?
                if let local = try await historyRepository.loadLocal(password: settingsSnapshot.historyPassword) {
                    guard generation == storageGeneration else { return false }
                    if !SyncConflictResolver.hasSameContent(local, database) {
                        database = local
                    }
                } else {
                    localBackupError = try await historyRepository.saveLocal(
                        database,
                        password: settingsSnapshot.historyPassword,
                        backupSettings: settingsSnapshot
                    )
                    guard generation == storageGeneration else { return false }
                }
                revision = ""
                hasPendingLocalChanges = false
                pollingFailureCount = 0
                if let localBackupError {
                    setSteadyStatus("Local history loaded, but the history backup could not be updated: \(localBackupError)")
                } else {
                    setSteadyStatus("Ready. Using local history.")
                }
                return true
            } catch {
                guard generation == storageGeneration else { return false }
                setSteadyStatus("Could not load local history: \(error.localizedDescription)")
                return false
            }
        }
        let client = ServerStorageClient(settings: settingsSnapshot)
        guard client.isConfigured else {
            if !settingsSnapshot.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !settingsSnapshot.serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               settingsSnapshot.historyPassword.isEmpty {
                setSteadyStatus("Clipman Server requires a unique history password. Your local cached history is unchanged.")
            } else {
                setSteadyStatus("Open Settings to configure Clipman Server.")
            }
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
            if showStatus, revision.isEmpty,
               let cached = try await historyRepository.loadLocal(password: settingsSnapshot.historyPassword) {
                guard generation == storageGeneration else { return false }
                if !SyncConflictResolver.hasSameContent(cached, database) {
                    database = cached
                }
                status = "Cached history loaded; refreshing Clipman Server."
            }
            if !showStatus && !revision.isEmpty && !hasPendingLocalChanges {
                let metadata = try await client.metadata()
                if metadata.revision == revision {
                    pollingFailureCount = 0
                    setSteadyStatus("Ready. Server sync connected.", revealImmediately: false)
                    return true
                }
            }
            let previousNewest = newestRemoteEntry(in: database)
            let sync = try await historyRepository.synchronize(
                settings: settingsSnapshot,
                current: database,
                localAlreadySaved: localCacheIsCurrent
            )
            guard generation == storageGeneration else { return false }
            let merged = sync.database
            if merged != database {
                database = merged
            }
            revision = sync.revision
            hasPendingLocalChanges = false
            pollingFailureCount = 0
            setSteadyStatus("Ready. Server sync connected.", revealImmediately: false)
            if !showStatus, previousNewest != nil, let newest = newestRemoteEntry(in: merged), newest.Id != previousNewest?.Id, newest.Id != lastRemoteEntryID {
                if settings.autoCopyRemote {
                    MobileRichTextClipboard.write(newest, includeRichText: settings.richTextEnabled)
                }
                lastRemoteEntryID = newest.Id
                let source = newest.SourceMachine.trimmingCharacters(in: .whitespacesAndNewlines)
                setTransientStatus(source.isEmpty ? "Clipboard updated by another device." : "Clipboard updated by \(source).")
                soundService.play("remote", soundsEnabled: settings.soundsEnabled, hapticsEnabled: settings.hapticsEnabled)
            }
            if showStatus {
                let message = sync.backupError.map {
                    "\(loadedStatusText()) History backup could not be updated: \($0)"
                } ?? loadedStatusText()
                if sync.backupError != nil {
                    setSteadyStatus(message)
                }
            } else if let backupError = sync.backupError {
                setSteadyStatus("History saved, but the history backup could not be updated: \(backupError)")
            }
            return true
        } catch {
            guard generation == storageGeneration else { return false }
            pollingFailureCount = min(pollingFailureCount + 1, 4)
            do {
                if let cached = try await historyRepository.loadLocal(password: settingsSnapshot.historyPassword) {
                    guard generation == storageGeneration else { return false }
                    if !SyncConflictResolver.hasSameContent(cached, database) {
                        database = cached
                    }
                    setSteadyStatus("Using local history; server sync is pending: \(error.localizedDescription)")
                    return true
                }
            } catch {
                guard generation == storageGeneration else { return false }
                setSteadyStatus("Could not load local history: \(error.localizedDescription)")
                return false
            }
            setSteadyStatus(error.localizedDescription)
            return false
        }
    }

    func requestClipboardImport(announceUnavailable: Bool = true) {
        guard MobileRichTextClipboard.containsText() else {
            if announceUnavailable {
                setTransientStatus("Clipboard does not contain text.")
                soundService.play("skip", soundsEnabled: settings.soundsEnabled, hapticsEnabled: settings.hapticsEnabled)
            }
            return
        }
        showingClipboardImport = true
    }

    func addPastedClipboardPayload(_ payload: MobileClipboardPayload?) {
        showingClipboardImport = false
        guard let payload,
              !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setTransientStatus("Clipboard does not contain text.")
            soundService.play("skip", soundsEnabled: settings.soundsEnabled, hapticsEnabled: settings.hapticsEnabled)
            return
        }
        let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let alreadyExists = database.Entries.contains { $0.Text == text }
        database = SyncConflictResolver.addText(
            database: database,
            text: text,
            machineName: machineName,
            richText: settings.richTextEnabled ? payload.richText : nil
        )
        setTransientStatus(alreadyExists ? "Clipboard text already exists in history." : "Clipboard text added.")
        soundService.play("copy", soundsEnabled: settings.soundsEnabled, hapticsEnabled: settings.hapticsEnabled)
        queueUpload(successMessage: nil)
    }

    func cancelClipboardImport() {
        showingClipboardImport = false
        setTransientStatus("Clipboard paste cancelled.")
    }

    func copy(_ entry: ClipEntry) {
        MobileRichTextClipboard.write(entry, includeRichText: settings.richTextEnabled)
        database = markUsed(entry)
        soundService.play("copy", soundsEnabled: settings.soundsEnabled, hapticsEnabled: settings.hapticsEnabled)
        setTransientStatus("Copied to clipboard.")
        queueUpload(successMessage: nil)
    }

    func copyText(_ text: String) {
        UIPasteboard.general.string = text
        soundService.play("copy", soundsEnabled: settings.soundsEnabled, hapticsEnabled: settings.hapticsEnabled)
        setTransientStatus("Copied to clipboard.")
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
        var normalized = entry
        normalized.Group = canonicalGroup(entry.Group)
        database = SyncConflictResolver.updateEntry(database: database, entry: normalized, machineName: machineName)
        queueUpload(successMessage: "Entry updated.")
    }

    private func canonicalGroup(_ requestedValue: String) -> String {
        let requested = requestedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { return "" }
        let matching = database.Entries.filter {
            $0.Group.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(requested) == .orderedSame
        }
        let spellings = Dictionary(grouping: matching) {
            $0.Group.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return spellings.values.map { entries in
            (
                label: entries[0].Group.trimmingCharacters(in: .whitespacesAndNewlines),
                count: entries.count,
                latest: entries.map { max($0.ModifiedUnixMs, $0.LastUsedUnixMs, $0.CreatedUnixMs) }.max() ?? 0
            )
        }
        .sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.latest != $1.latest { return $0.latest > $1.latest }
            return $0.label < $1.label
        }
        .first?.label ?? requested
    }

    private func queueUpload(successMessage: String?) {
        uploadTask?.cancel()
        if let successMessage {
            setTransientStatus(successMessage)
        }
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
            let localBackupError = try await historyRepository.saveLocal(
                snapshot,
                password: settingsSnapshot.historyPassword,
                backupSettings: settingsSnapshot
            )
            try Task.checkCancellation()
            guard generation == storageGeneration else { return }
            if settingsSnapshot.storageMode == .local {
                hasPendingLocalChanges = false
                setSteadyStatus("Ready. Using local history.", revealImmediately: false)
                if let localBackupError {
                    setSteadyStatus("Saved locally, but the history backup could not be updated: \(localBackupError)")
                }
                return
            }
            let sync = try await historyRepository.synchronize(
                settings: settingsSnapshot,
                current: snapshot,
                localAlreadySaved: true
            )
            try Task.checkCancellation()
            guard generation == storageGeneration else { return }
            revision = sync.revision
            hasPendingLocalChanges = false
            setSteadyStatus("Ready. Server sync connected.", revealImmediately: false)
            if !SyncConflictResolver.hasSameContent(sync.database, database) {
                database = sync.database
            }
            if let backupError = sync.backupError ?? localBackupError {
                setSteadyStatus("History backup could not be updated: \(backupError)")
            }
        } catch is CancellationError {
            return
        } catch {
            hasPendingLocalChanges = settingsSnapshot.storageMode == .server
            let failure = settingsSnapshot.storageMode == .server
                ? "Saved locally; server sync is pending: \(error.localizedDescription)"
                : "Could not save local history: \(error.localizedDescription)"
            setSteadyStatus(failure)
            soundService.play("skip", soundsEnabled: settings.soundsEnabled, hapticsEnabled: settings.hapticsEnabled)
        }
    }

    func mergeHistoryBackup(_ data: Data) async throws {
        guard !settings.historyPassword.isEmpty else {
            throw CloudHistoryBackupError.unencryptedBackup
        }
        let imported = try await DatabaseWorker.load(data: data, password: settings.historyPassword)
        let merged = SyncConflictResolver.merge(target: database, source: imported)
        guard !SyncConflictResolver.hasSameContent(merged, database) else {
            status = "History backup contained no newer changes."
            return
        }
        database = merged
        queueUpload(successMessage: "History backup merged.")
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
        let richText = settings.richTextEnabled ? database.Entries.filter { $0.RichText != nil }.count : 0
        let remaining = settings.richTextEnabled ? database.Entries.filter { $0.RichText == nil } : database.Entries
        let links = remaining.filter { pureLinkEntryIDs.contains($0.Id) }.count
        let text = max(0, remaining.count - links)
        let richPart = settings.richTextEnabled ? ", \(richText) rich text" : ""
        return "Loaded \(total) clipboard entries: \(text) text\(richPart), \(links) links."
    }
}
