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
    @Published var isRefreshing = false
    @Published private(set) var linkItems: [LinkExtractor.LinkItem] = []

    private let soundService = SoundService()
    private var revision = ""
    private var refreshTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var refreshInProgress = false
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
        Task {
            if await AuthenticationService.unlock() {
                isUnlocked = true
                await refresh(showStatus: true)
                startPolling()
            } else {
                status = "Authentication cancelled."
            }
        }
    }

    func saveSettings(_ newSettings: ClipmanSettings) {
        settings = newSettings
        if !settings.linksEnabled && selectedSection == .links {
            selectedSection = .text
        }
        SettingsStore.save(newSettings)
        revision = ""
        startPolling()
        Task { await refresh(showStatus: true) }
    }

    func startPolling() {
        refreshTask?.cancel()
        guard settings.refreshIntervalSeconds >= 2 else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(2, self?.settings.refreshIntervalSeconds ?? 3) * 1_000_000_000))
                await self?.refresh(showStatus: false)
            }
        }
    }

    func refresh(showStatus: Bool) async {
        guard !refreshInProgress else { return }
        let client = ServerStorageClient(settings: settings)
        guard client.isConfigured else {
            status = "Open Settings to configure Clipman Server."
            showingSettings = true
            return
        }
        refreshInProgress = true
        if showStatus { isRefreshing = true }
        defer {
            refreshInProgress = false
            if showStatus { isRefreshing = false }
        }
        do {
            if !showStatus && !revision.isEmpty {
                let metadata = try await client.metadata()
                if metadata.revision == revision {
                    return
                }
            }
            let download = try await client.download()
            let merged = try await DatabaseWorker.loadAndMerge(data: download.data, password: settings.historyPassword, current: database)
            let previousNewest = newestRemoteEntry(in: database)
            if merged != database {
                database = merged
            }
            revision = download.revision
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
        } catch ServerStorageError.notFound {
            database = ClipDatabase()
            await uploadDatabase(database, expectedRevision: "", successMessage: "Created server database.")
        } catch {
            status = error.localizedDescription
        }
    }

    func addCurrentClipboard() {
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            status = "Clipboard does not contain text."
            soundService.play("skip", soundsEnabled: settings.soundsEnabled, hapticsEnabled: settings.hapticsEnabled)
            return
        }
        database = SyncConflictResolver.addText(database: database, text: text, machineName: machineName)
        queueUpload(successMessage: "Clipboard text added.")
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
        let currentRevision = revision
        uploadTask = Task { [weak self] in
            await self?.uploadDatabase(snapshot, expectedRevision: currentRevision, successMessage: successMessage)
        }
    }

    private func uploadDatabase(_ snapshot: ClipDatabase, expectedRevision: String, successMessage: String?) async {
        var expectedRevision = expectedRevision
        var snapshot = snapshot
        for attempt in 0..<3 {
            let client = ServerStorageClient(settings: settings)
            guard client.isConfigured else {
                status = "Open Settings to configure Clipman Server."
                return
            }
            do {
                let data = try await DatabaseWorker.save(snapshot, password: settings.historyPassword)
                revision = try await client.upload(data: data, expectedRevision: expectedRevision)
                if let successMessage {
                    status = successMessage
                }
                return
            } catch ServerStorageError.conflict where attempt < 2 {
                do {
                    let download = try await client.download()
                    let merged = try await DatabaseWorker.loadAndMerge(data: download.data, password: settings.historyPassword, current: snapshot)
                    snapshot = merged
                    if merged != database {
                        database = merged
                    }
                    expectedRevision = download.revision
                } catch {
                    status = error.localizedDescription
                    soundService.play("skip", soundsEnabled: settings.soundsEnabled, hapticsEnabled: settings.hapticsEnabled)
                    return
                }
            } catch {
                status = error.localizedDescription
                soundService.play("skip", soundsEnabled: settings.soundsEnabled, hapticsEnabled: settings.hapticsEnabled)
                return
            }
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
            let trimmed = entry.Text.trimmingCharacters(in: .whitespacesAndNewlines)
            if links.count == 1, let url = links.first, trimmed == url.absoluteString {
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
