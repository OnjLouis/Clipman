import Foundation
import CryptoKit
import ClipmanCore

@MainActor
protocol ClipStoreDelegate: AnyObject {
    func clipStoreDidChange()
    func clipStoreNeedsPassword(for path: String) -> String?
    func clipStoreDidFail(error: Error)
    func clipStoreServerSyncDidRecover()
    /// Announces that entries were written straight through to a channel this
    /// device does not subscribe to (sync-rules-spec.md section 6). They never
    /// appear in the local view, so this is the only feedback the user gets.
    func clipStoreDidWriteThrough(channelNames: [String])
}

/// One sync channel as it stood at the last transfer. `key` is `""` for the
/// core channel, which keeps using the existing history file and, in server
/// mode, the configured database id. `plainHash` is the durable dirty-detection
/// hash of spec section 5, upload step 4.
private struct ChannelSlot {
    var key: String
    var url: URL
    var databaseID: String
    var database = ClipDatabase()
    var revision = ""
    var existsOnServer = false
    var plainHash = Data()
    /// The entries this channel was fetched with, before the current save
    /// changed anything. Phase one of an upload carries these copies for
    /// departing entries (spec section 5, upload step 5).
    var fetched: [String: ClipEntry] = [:]
}

struct ServerSyncStatus {
    var enabled = false
    var configured = false
    var revision = ""
    var lastPollUnixMs: Int64 = 0
    var lastSuccessUnixMs: Int64 = 0
    var lastUploadUnixMs: Int64 = 0
    var nextPollUnixMs: Int64 = 0
    var consecutiveFailures = 0
}

enum ClipStoreAddResult: Equatable, Sendable {
    case saved
    case failed
    case refused(String)
}

struct ServerSyncFailureError: Error, LocalizedError {
    let underlying: Error

    var errorDescription: String? {
        underlying.localizedDescription
    }
}

final class ClipStore: @unchecked Sendable {
    weak var delegate: ClipStoreDelegate?

    private let queue = DispatchQueue(label: "Clipman.ClipStore")
    private let serverRequestQueue = DispatchQueue(label: "Clipman.ClipStore.ServerRequests", qos: .utility)
    private var database = ClipDatabase()
    private var source: DispatchSourceFileSystemObject?
    private var reloadWorkItem: DispatchWorkItem?
    private var fileDescriptor: CInt = -1
    private var password = ""
    private(set) var databaseURL: URL
    private var machineName: String
    private var serverClient: ServerStorageClient?
    private var serverRevision = ""
    private var serverPollTimer: DispatchSourceTimer?
    private var serverSyncInProgress = false
    private var serverPollInProgress = false
    private var serverConfigurationGeneration: UInt64 = 0
    private var serverFailureReported = false
    private var serverUploadPending = false
    private var serverLastPollUnixMs: Int64 = 0
    private var serverLastSuccessUnixMs: Int64 = 0
    private var serverLastUploadUnixMs: Int64 = 0
    private var serverNextPollUnixMs: Int64 = 0
    private var serverConsecutiveFailures = 0
    private var serverToken = ""

    // Sync channels (sync-rules-spec.md sections 4 to 6). With no rules document,
    // or a disabled one, every one of these stays empty and each code path below
    // takes its legacy branch, so behavior is identical to a client without the
    // feature.
    private var rulesDocument: SyncRulesDocument?
    /// The revision an edit may claim to be based on. It is deliberately blank
    /// whenever the cached document, not the server's, is the one in effect.
    private var rulesRevision = ""
    /// The revision the rules bucket was last downloaded at, which is what the
    /// poll compares against so an unchanged bucket is never fetched twice.
    private var rulesServerRevision = ""
    private var rulesExistsOnServer = false
    /// Armed when a rules upload fails so the next successful poll retries it;
    /// see `publishRulesLocked`.
    private var rulesUploadPending = false
    private var rulesCacheHash = Data()
    private var channelSlots: [ChannelSlot] = []
    private var residence: [String: String] = [:]
    private var viewMarkers: [String: DeletedClipEntry] = [:]
    private var pendingChannelWrites: [String: [ClipEntry]] = [:]

    init(databaseURL: URL, machineName: String) {
        self.databaseURL = databaseURL
        self.machineName = machineName
    }

    func setMachineName(_ value: String) {
        queue.sync {
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && name != self.machineName {
                self.machineName = name
                // Subscriptions are keyed on the device name, so renaming this
                // Mac can change which channels it downloads.
                self.rebuildChannelSlotsLocked()
            }
        }
    }

    deinit {
        serverPollTimer?.cancel()
    }

    func setDatabaseURL(_ url: URL, password: String = "") {
        queue.async {
            self.databaseURL = url
            self.password = password
            let loaded = self.loadLocked()
            self.resetWatcherLocked()
            if loaded {
                DispatchQueue.main.async { self.delegate?.clipStoreDidChange() }
            }
        }
    }

    func configureServerStorage(
        enabled: Bool,
        serverURL: String,
        serverToken: String,
        serverCaCertPEM: String,
        serverCaHost: String
    ) {
        queue.async {
            self.serverPollTimer?.cancel()
            self.serverPollTimer = nil
            self.serverConfigurationGeneration &+= 1
            self.serverPollInProgress = false
            self.serverRevision = ""
            self.serverToken = serverToken
            self.resetServerStatusLocked()
            self.rulesRevision = ""
            self.rulesServerRevision = ""
            self.rulesExistsOnServer = false
            self.rulesUploadPending = false
            self.serverClient = enabled ? ServerStorageClient(
                serverURL: serverURL,
                token: serverToken,
                databasePassword: self.password,
                caCertPEM: serverCaCertPEM,
                caHost: serverCaHost
            ) : nil
            guard let client = self.serverClient, client.isConfigured else {
                self.serverClient = nil
                self.rebuildChannelSlotsLocked()
                if self.serverFailureReported {
                    self.serverFailureReported = false
                    DispatchQueue.main.async { self.delegate?.clipStoreServerSyncDidRecover() }
                }
                return
            }
            self.rebuildChannelSlotsLocked()

            self.startServerPollTimerLocked()
            self.pollServerLocked()
        }
    }

    func retryServerSync() {
        queue.async {
            self.serverNextPollUnixMs = 0
            self.pollServerLocked()
        }
    }

    func load() {
        queue.async {
            let loaded = self.loadLocked()
            self.resetWatcherLocked()
            if loaded {
                DispatchQueue.main.async { self.delegate?.clipStoreDidChange() }
            }
        }
    }

    func entries() -> [ClipEntry] {
        queue.sync { sortedEntriesLocked() }
    }

    func entries(sortMode: String, descending: Bool) -> [ClipEntry] {
        queue.sync { sortedEntriesLocked(sortMode: sortMode, descending: descending) }
    }

    func entryCount() -> Int {
        queue.sync { database.Entries.count }
    }

    func serverSyncStatus() -> ServerSyncStatus {
        queue.sync {
            ServerSyncStatus(
                enabled: serverClient != nil,
                configured: serverClient?.isConfigured == true,
                revision: serverRevision,
                lastPollUnixMs: serverLastPollUnixMs,
                lastSuccessUnixMs: serverLastSuccessUnixMs,
                lastUploadUnixMs: serverLastUploadUnixMs,
                nextPollUnixMs: serverNextPollUnixMs,
                consecutiveFailures: serverConsecutiveFailures
            )
        }
    }

    func newestRemoteCreatedEntry(excluding sourceMachine: String) -> ClipEntry? {
        queue.sync {
            database.Entries
                .filter {
                    !$0.Text.isEmpty
                    && $0.CreatedUnixMs > 0
                    && !$0.SourceMachine.isEmpty
                    && $0.SourceMachine.caseInsensitiveCompare(sourceMachine) != .orderedSame
                }
                .max {
                    if $0.CreatedUnixMs == $1.CreatedUnixMs { return $0.Id < $1.Id }
                    return $0.CreatedUnixMs < $1.CreatedUnixMs
                }
        }
    }

    func hasRecentlyTouchedRemoteText(_ text: String, excluding sourceMachine: String, within milliseconds: Int64 = 90_000) -> Bool {
        guard !text.isEmpty else { return false }
        let cutoff = TimeUtil.nowUnixMs() - milliseconds
        return queue.sync {
            database.Entries.contains {
                $0.Text == text
                && !$0.SourceMachine.isEmpty
                && $0.SourceMachine.caseInsensitiveCompare(sourceMachine) != .orderedSame
                && max($0.CreatedUnixMs, $0.LastUsedUnixMs) >= cutoff
            }
        }
    }

    func entry(id: String) -> ClipEntry? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return queue.sync {
            database.Entries.first { $0.Id == trimmed }
        }
    }

    func addText(_ text: String, group: String = "", richText: RichTextPayload? = nil, maxEntries: Int = 1000, completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        addTextWithResult(text, group: group, richText: richText, maxEntries: maxEntries) { result in
            completion?(result == .saved)
        }
    }

    func addTextWithResult(
        _ text: String,
        group: String = "",
        richText: RichTextPayload? = nil,
        maxEntries: Int = 1000,
        maxEmbeddedImageBytes: Int? = nil,
        completion: (@MainActor @Sendable (ClipStoreAddResult) -> Void)? = nil
    ) {
        guard !text.isEmpty else {
            Task { @MainActor in
                completion?(.failed)
            }
            return
        }
        let trimmedGroup = group.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRichText = RichTextData.normalize(richText)
        let incomingImage = EmbeddedImageHTML.imageInfo(from: normalizedRichText)
        queue.async {
            guard self.mergeLatestBeforeWriteLocked() else {
                Task { @MainActor in
                    completion?(.failed)
                }
                return
            }
            let now = TimeUtil.nowUnixMs()
            let normalizedGroup = self.canonicalGroupLocked(trimmedGroup)
            let matchingIndex = self.database.Entries.firstIndex(where: { $0.Text == text })
            if let maxEmbeddedImageBytes, let incomingImage {
                let existingBytes = self.database.Entries.enumerated().reduce(0) { total, pair in
                    pair.offset == matchingIndex ? total : total + (EmbeddedImageHTML.imageInfo(from: pair.element.RichText)?.data.count ?? 0)
                }
                if existingBytes + incomingImage.data.count > maxEmbeddedImageBytes {
                    Task { @MainActor in
                        completion?(.refused("Rich Text history already uses its 8 MiB embedded-image allowance."))
                    }
                    return
                }
            }
            if let index = matchingIndex {
                self.database.Entries[index].LastUsedUnixMs = now
                self.database.Entries[index].SourceMachine = self.machineName
                if let richText = normalizedRichText {
                    self.database.Entries[index].RichText = richText
                    self.database.Entries[index].RichTextUpdatedUnixMs = now
                }
                if !normalizedGroup.isEmpty {
                    self.database.Entries[index].Group = normalizedGroup
                    self.database.Entries[index].ModifiedUnixMs = now
                }
            } else {
                self.database.Entries.append(ClipEntry(
                    Text: text,
                    Group: normalizedGroup,
                    SourceMachine: self.machineName,
                    CreatedUnixMs: now,
                    LastUsedUnixMs: now,
                    ModifiedUnixMs: now,
                    ManualOrder: self.nextManualOrderLocked(),
                    RichText: normalizedRichText,
                    RichTextUpdatedUnixMs: normalizedRichText == nil ? 0 : now
                ))
            }
            self.pruneLocked(maxEntries: maxEntries)
            let saved = self.saveLocked()
            Task { @MainActor in
                if saved {
                    self.delegate?.clipStoreDidChange()
                }
                completion?(saved ? .saved : .failed)
            }
        }
    }

    func entryID(forText text: String) -> String {
        queue.sync { database.Entries.first(where: { $0.Text == text })?.Id ?? "" }
    }

    func mergeCapturedText(baseID: String, baseText: String, firstTapID: String, firstTapText: String, mergedText: String, group: String, completion: (@MainActor @Sendable (String?) -> Void)? = nil) {
        guard !mergedText.isEmpty else {
            Task { @MainActor in completion?(nil) }
            return
        }
        queue.async {
            guard self.mergeLatestBeforeWriteLocked() else {
                Task { @MainActor in completion?(nil) }
                return
            }
            let newestMatchingIndex: (String) -> Int? = { text in
                self.database.Entries.indices
                    .filter { !self.database.Entries[$0].Pinned && self.database.Entries[$0].Text == text }
                    .max { self.database.Entries[$0].LastUsedUnixMs < self.database.Entries[$1].LastUsedUnixMs }
            }
            let baseIndex = baseID.isEmpty
                ? newestMatchingIndex(baseText)
                : self.database.Entries.firstIndex { $0.Id.caseInsensitiveCompare(baseID) == .orderedSame }
            let firstIndex = firstTapID.isEmpty
                ? newestMatchingIndex(firstTapText)
                : self.database.Entries.firstIndex { $0.Id.caseInsensitiveCompare(firstTapID) == .orderedSame }
            let targetID: String?
            if let baseIndex, !self.database.Entries[baseIndex].Pinned {
                targetID = self.database.Entries[baseIndex].Id
            } else if let firstIndex, !self.database.Entries[firstIndex].Pinned {
                targetID = self.database.Entries[firstIndex].Id
            } else {
                targetID = nil
            }
            let now = TimeUtil.nowUnixMs()
            let savedID: String
            if let targetID, let index = self.database.Entries.firstIndex(where: { $0.Id == targetID }) {
                self.database.Entries[index].Text = mergedText
                self.database.Entries[index].SourceMachine = self.machineName
                self.database.Entries[index].LastUsedUnixMs = now
                self.database.Entries[index].ModifiedUnixMs = now
                self.database.Entries[index].IsTemplate = false
                self.database.Entries[index].RichText = nil
                self.database.Entries[index].RichTextUpdatedUnixMs = now
                if self.database.Entries[index].Group.isEmpty && !group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.database.Entries[index].Group = self.canonicalGroupLocked(group)
                }
                savedID = targetID
            } else {
                let entry = ClipEntry(
                    Text: mergedText,
                    Group: self.canonicalGroupLocked(group),
                    SourceMachine: self.machineName,
                    CreatedUnixMs: now,
                    LastUsedUnixMs: now,
                    ModifiedUnixMs: now,
                    ManualOrder: self.nextManualOrderLocked()
                )
                self.database.Entries.append(entry)
                savedID = entry.Id
            }
            let partialIndex = firstTapID.isEmpty
                ? newestMatchingIndex(firstTapText).flatMap { self.database.Entries[$0].Id == savedID ? nil : $0 }
                : self.database.Entries.firstIndex(where: {
                    $0.Id.caseInsensitiveCompare(firstTapID) == .orderedSame && $0.Id != savedID && !$0.Pinned
                })
            if let partialIndex {
                let partial = self.database.Entries.remove(at: partialIndex)
                SyncConflictResolver.addDeletedEntry(id: partial.Id, text: partial.Text, machineName: self.machineName, to: &self.database)
            }
            self.pruneLocked(maxEntries: 1000)
            let saved = self.saveLocked()
            Task { @MainActor in
                if saved { self.delegate?.clipStoreDidChange() }
                completion?(saved ? savedID : nil)
            }
        }
    }

    func pushEntriesToOtherMachines(ids: [String]) {
        let idSet = Set(ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !idSet.isEmpty else { return }
        queue.async {
            guard self.mergeLatestBeforeWriteLocked() else { return }
            let selected = self.database.Entries.filter { idSet.contains($0.Id) && !$0.Text.isEmpty }
            guard !selected.isEmpty else { return }

            var now = TimeUtil.nowUnixMs()
            for entry in selected {
                guard let index = self.database.Entries.firstIndex(where: { $0.Id == entry.Id }) else { continue }
                self.database.Entries[index].SourceMachine = self.machineName
                self.database.Entries[index].CreatedUnixMs = now
                self.database.Entries[index].LastUsedUnixMs = now
                now += 1
            }

            self.saveLocked()
            DispatchQueue.main.async { self.delegate?.clipStoreDidChange() }
        }
    }

    func markUsed(_ id: String) {
        queue.async {
            guard self.mergeLatestBeforeWriteLocked() else { return }
            guard let index = self.database.Entries.firstIndex(where: { $0.Id == id }) else { return }
            self.database.Entries[index].LastUsedUnixMs = TimeUtil.nowUnixMs()
            self.saveLocked()
        }
    }

    func togglePinned(_ id: String) {
        queue.async {
            guard self.mergeLatestBeforeWriteLocked() else { return }
            guard let index = self.database.Entries.firstIndex(where: { $0.Id == id }) else { return }
            self.database.Entries[index].Pinned.toggle()
            self.database.Entries[index].ModifiedUnixMs = TimeUtil.nowUnixMs()
            self.saveLocked()
            DispatchQueue.main.async { self.delegate?.clipStoreDidChange() }
        }
    }

    func delete(_ id: String) {
        queue.async {
            guard self.mergeLatestBeforeWriteLocked() else { return }
            guard let index = self.database.Entries.firstIndex(where: { $0.Id == id }),
                  !self.database.Entries[index].Pinned else {
                return
            }
            let deletedText = self.database.Entries[index].Text
            self.database.Entries.remove(at: index)
            SyncConflictResolver.addDeletedEntry(id: id, text: deletedText, machineName: self.machineName, to: &self.database)
            self.saveLocked()
            DispatchQueue.main.async { self.delegate?.clipStoreDidChange() }
        }
    }

    func setNameAndText(id: String, name: String, text: String) {
        queue.async {
            guard self.mergeLatestBeforeWriteLocked() else { return }
            guard let index = self.database.Entries.firstIndex(where: { $0.Id == id }) else { return }
            let now = TimeUtil.nowUnixMs()
            self.database.Entries[index].Name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let textChanged = self.database.Entries[index].Text != text
            self.database.Entries[index].Text = text
            self.database.Entries[index].LastUsedUnixMs = now
            self.database.Entries[index].ModifiedUnixMs = now
            if textChanged {
                self.database.Entries[index].RichText = nil
                self.database.Entries[index].RichTextUpdatedUnixMs = self.database.Entries[index].LastUsedUnixMs
            }
            self.saveLocked()
            DispatchQueue.main.async { self.delegate?.clipStoreDidChange() }
        }
    }

    func setNameIfEmpty(id: String, expectedText: String, name: String, completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            Task { @MainActor in completion?(false) }
            return
        }
        queue.async {
            guard self.mergeLatestBeforeWriteLocked(),
                  let index = self.database.Entries.firstIndex(where: { $0.Id == id }),
                  self.database.Entries[index].Text == expectedText,
                  self.database.Entries[index].Name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                Task { @MainActor in completion?(false) }
                return
            }
            self.database.Entries[index].Name = trimmedName
            self.database.Entries[index].ModifiedUnixMs = TimeUtil.nowUnixMs()
            let saved = self.saveLocked()
            Task { @MainActor in
                if saved { self.delegate?.clipStoreDidChange() }
                completion?(saved)
            }
        }
    }

    func setTemplate(id: String, isTemplate: Bool) {
        queue.async {
            guard self.mergeLatestBeforeWriteLocked() else { return }
            guard let index = self.database.Entries.firstIndex(where: { $0.Id == id }) else { return }
            self.database.Entries[index].IsTemplate = isTemplate
            self.database.Entries[index].ModifiedUnixMs = TimeUtil.nowUnixMs()
            self.saveLocked()
            DispatchQueue.main.async { self.delegate?.clipStoreDidChange() }
        }
    }

    func setGroup(ids: [String], group: String) {
        let idSet = Set(ids)
        let trimmed = group.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !idSet.isEmpty else { return }
        queue.async {
            guard self.mergeLatestBeforeWriteLocked() else { return }
            let normalizedGroup = self.canonicalGroupLocked(trimmed)
            var changed = false
            let now = TimeUtil.nowUnixMs()
            for index in self.database.Entries.indices where idSet.contains(self.database.Entries[index].Id) {
                self.database.Entries[index].Group = normalizedGroup
                self.database.Entries[index].LastUsedUnixMs = now
                self.database.Entries[index].ModifiedUnixMs = now
                changed = true
            }
            guard changed else { return }
            self.saveLocked()
            DispatchQueue.main.async { self.delegate?.clipStoreDidChange() }
        }
    }

    private func canonicalGroupLocked(_ requested: String) -> String {
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

    func moveEntries(ids: [String], direction: Int) {
        let idSet = Set(ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !idSet.isEmpty, direction != 0 else { return }
        queue.async {
            guard self.mergeLatestBeforeWriteLocked() else { return }
            self.normalizeManualOrderLocked()
            let selected = self.database.Entries.filter { idSet.contains($0.Id) }
            guard let first = selected.first,
                  !selected.contains(where: { $0.Pinned != first.Pinned }) else {
                return
            }

            var ordered = self.database.Entries
                .filter { $0.Pinned == first.Pinned }
                .sorted {
                    if $0.ManualOrder == $1.ManualOrder { return $0.CreatedUnixMs < $1.CreatedUnixMs }
                    return $0.ManualOrder < $1.ManualOrder
                }
            let indexes = ordered.indices.filter { idSet.contains(ordered[$0].Id) }
            guard let firstIndex = indexes.first, let lastIndex = indexes.last else { return }
            if direction < 0, firstIndex == 0 { return }
            if direction > 0, lastIndex >= ordered.count - 1 { return }

            let moving = ordered.filter { idSet.contains($0.Id) }
            ordered.removeAll { idSet.contains($0.Id) }
            let insertionIndex: Int
            if direction < 0 {
                insertionIndex = max(0, firstIndex - 1)
            } else {
                insertionIndex = min(ordered.count, lastIndex + 1 - moving.count + 1)
            }
            ordered.insert(contentsOf: moving, at: insertionIndex)

            let now = TimeUtil.nowUnixMs()
            for (offset, entry) in ordered.enumerated() {
                guard let index = self.database.Entries.firstIndex(where: { $0.Id == entry.Id }) else { continue }
                let nextOrder = Int64(offset + 1)
                if self.database.Entries[index].ManualOrder != nextOrder {
                    self.database.Entries[index].ManualOrder = nextOrder
                    self.database.Entries[index].ModifiedUnixMs = now
                }
            }
            self.saveLocked()
            DispatchQueue.main.async { self.delegate?.clipStoreDidChange() }
        }
    }

    func insertTextsAfterSelected(
        _ entries: [ClipEntry],
        afterID: String?,
        maxEmbeddedImageBytes: Int? = nil,
        completion: (@MainActor @Sendable (ClipStoreAddResult) -> Void)? = nil
    ) {
        queue.async {
            let source = entries.compactMap { entry -> ClipEntry? in
                guard !entry.Text.isEmpty else { return nil }
                var normalized = entry
                normalized.RichText = RichTextData.normalize(entry.RichText)
                return normalized
            }
            guard !source.isEmpty else {
                Task { @MainActor in completion?(.failed) }
                return
            }
            guard self.mergeLatestBeforeWriteLocked() else {
                Task { @MainActor in completion?(.failed) }
                return
            }
            if let maxEmbeddedImageBytes {
                let replacedTexts = Set(source.map(\.Text))
                let existingBytes = self.database.Entries.reduce(0) { total, entry in
                    guard !replacedTexts.contains(entry.Text) else { return total }
                    return total + (EmbeddedImageHTML.imageInfo(from: entry.RichText)?.data.count ?? 0)
                }
                let incomingBytes = source.reduce(0) { total, entry in
                    total + (EmbeddedImageHTML.imageInfo(from: entry.RichText)?.data.count ?? 0)
                }
                guard existingBytes + incomingBytes <= maxEmbeddedImageBytes else {
                    Task { @MainActor in
                        completion?(.refused("Rich Text history already uses its 8 MiB embedded-image allowance."))
                    }
                    return
                }
            }
            let now = TimeUtil.nowUnixMs()
            let order: Int64
            if let afterID,
               let after = self.database.Entries.first(where: { $0.Id == afterID }) {
                order = after.ManualOrder + 1
            } else {
                order = self.nextManualOrderLocked()
            }
            for index in self.database.Entries.indices where self.database.Entries[index].ManualOrder >= order {
                self.database.Entries[index].ManualOrder += Int64(source.count)
            }
            for (offset, entry) in source.enumerated() {
                self.database.Entries.removeAll { $0.Text == entry.Text }
                self.database.Entries.append(ClipEntry(
                    Text: entry.Text,
                    Name: entry.Name,
                    Group: entry.Group,
                    SourceMachine: entry.SourceMachine.isEmpty ? self.machineName : entry.SourceMachine,
                    CreatedUnixMs: entry.CreatedUnixMs == 0 ? now : entry.CreatedUnixMs,
                    LastUsedUnixMs: entry.LastUsedUnixMs == 0 ? now : entry.LastUsedUnixMs,
                    ModifiedUnixMs: entry.ModifiedUnixMs == 0 ? now : entry.ModifiedUnixMs,
                    Pinned: false,
                    IsTemplate: entry.IsTemplate,
                    ManualOrder: order + Int64(offset),
                    RichText: entry.RichText,
                    RichTextUpdatedUnixMs: entry.RichText == nil ? 0 : now
                ))
            }
            SyncConflictResolver.normalize(&self.database)
            let saved = self.saveLocked()
            Task { @MainActor in
                if saved {
                    self.delegate?.clipStoreDidChange()
                }
                completion?(saved ? .saved : .failed)
            }
        }
    }

    func importEntries(from url: URL, importPassword: String? = nil, completion: @escaping @Sendable (Result<Int, Error>) -> Void) {
        queue.async {
            do {
                guard self.mergeLatestBeforeWriteLocked() else {
                    DispatchQueue.main.async { completion(.failure(ClipDatabaseError.passwordRequired)) }
                    return
                }
                let imported = try self.loadImportedEntriesLocked(from: url, importPassword: importPassword)
                var added = 0
                for var entry in imported where !entry.Text.isEmpty {
                    if self.database.Entries.contains(where: { $0.Text == entry.Text }) { continue }
                    if entry.Id.isEmpty {
                        entry.Id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                    }
                    if entry.CreatedUnixMs == 0 {
                        entry.CreatedUnixMs = TimeUtil.nowUnixMs()
                    }
                    if entry.LastUsedUnixMs == 0 {
                        entry.LastUsedUnixMs = entry.CreatedUnixMs
                    }
                    if entry.ModifiedUnixMs == 0 {
                        entry.ModifiedUnixMs = TimeUtil.nowUnixMs()
                    }
                    if entry.ManualOrder <= 0 {
                        entry.ManualOrder = self.nextManualOrderLocked()
                    }
                    if entry.SourceMachine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        entry.SourceMachine = self.machineName
                    }
                    self.database.Entries.append(entry)
                    added += 1
                }
                if added > 0 {
                    SyncConflictResolver.normalize(&self.database)
                    self.saveLocked()
                }
                DispatchQueue.main.async {
                    self.delegate?.clipStoreDidChange()
                    completion(.success(added))
                }
            } catch {
                DispatchQueue.main.async {
                    self.delegate?.clipStoreDidFail(error: error)
                    completion(.failure(error))
                }
            }
        }
    }

    func exportDatabase(to url: URL, exportPassword: String? = nil, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async {
            do {
                guard self.mergeLatestBeforeWriteLocked() else {
                    DispatchQueue.main.async { completion(.failure(ClipDatabaseError.passwordRequired)) }
                    return
                }
                if url.pathExtension.caseInsensitiveCompare("txt") == .orderedSame {
                    let text = self.sortedEntriesLocked().map(\.Text).joined(separator: "\n---\n")
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try text.write(to: url, atomically: true, encoding: .utf8)
                } else {
                    var snapshot = self.database
                    snapshot.UpdatedUnixMs = TimeUtil.nowUnixMs()
                    try ClipDatabaseFile.saveAtomic(url, database: snapshot, password: exportPassword ?? self.exportPassword(for: url))
                }
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async {
                    self.delegate?.clipStoreDidFail(error: error)
                    completion(.failure(error))
                }
            }
        }
    }

    func replaceTexts(_ updates: [(id: String, text: String)]) {
        let updateMap = Dictionary(uniqueKeysWithValues: updates.map { ($0.id, $0.text) })
        guard !updateMap.isEmpty else { return }
        queue.async {
            guard self.mergeLatestBeforeWriteLocked() else { return }
            var changed = false
            let now = TimeUtil.nowUnixMs()
            for index in self.database.Entries.indices {
                guard let text = updateMap[self.database.Entries[index].Id],
                      self.database.Entries[index].Text != text
                else { continue }
                self.database.Entries[index].Text = text
                self.database.Entries[index].LastUsedUnixMs = now
                self.database.Entries[index].ModifiedUnixMs = now
                changed = true
            }
            guard changed else { return }
            self.saveLocked()
            DispatchQueue.main.async { self.delegate?.clipStoreDidChange() }
        }
    }

    func currentPassword() -> String {
        queue.sync { password }
    }

    private func loadImportedEntriesLocked(from url: URL, importPassword: String? = nil) throws -> [ClipEntry] {
        if url.pathExtension.caseInsensitiveCompare("txt") == .orderedSame {
            let content = try String(contentsOf: url, encoding: .utf8)
            return content
                .components(separatedBy: "\n---\n")
                .flatMap { $0.components(separatedBy: "\r\n---\r\n") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map {
                    ClipEntry(
                        Text: $0,
                        SourceMachine: machineName,
                        CreatedUnixMs: TimeUtil.nowUnixMs(),
                        LastUsedUnixMs: TimeUtil.nowUnixMs(),
                        ManualOrder: nextManualOrderLocked()
                    )
                }
        }

        let imported = try ClipDatabaseFile.load(url, password: importPassword ?? exportPassword(for: url))
        return imported.Entries.filter { !$0.Text.isEmpty }
    }

    private func exportPassword(for url: URL) -> String {
        url.pathExtension.caseInsensitiveCompare("clipdb") == .orderedSame ? password : ""
    }

    private func loadLocked() -> Bool {
        do {
            _ = try SyncConflictResolver.resolveDatabaseConflicts(databaseURL: databaseURL, password: password)
            database = try loadDatabaseWithPasswordLocked()
            normalizeManualOrderLocked()
            loadPendingChannelWritesLocked()
            refreshRulesFromDiskLocked()
            if rulesActiveLocked() {
                try loadChannelsFromDiskLocked()
                assembleViewLocked()
            } else {
                clearChannelStateLocked()
            }
            return true
        } catch {
            DispatchQueue.main.async { self.delegate?.clipStoreDidFail(error: error) }
            return false
        }
    }

    private func loadDatabaseWithPasswordLocked() throws -> ClipDatabase {
        do {
            return try ClipDatabaseFile.load(databaseURL, password: password)
        } catch ClipDatabaseError.passwordRequired, ClipDatabaseError.incorrectPassword {
            if let supplied = DispatchQueue.main.sync(execute: { delegate?.clipStoreNeedsPassword(for: databaseURL.path) }) {
                password = supplied
                return try ClipDatabaseFile.load(databaseURL, password: supplied)
            }
            throw ClipDatabaseError.passwordRequired
        }
    }

    private func mergeLatestBeforeWriteLocked() -> Bool {
        do {
            if shouldAttemptSynchronousServerRequestLocked() {
                do {
                    try syncFromServerLocked(uploadLocalWhenMissing: false)
                } catch {
                    markServerFailureLocked()
                    reportServerFailureLocked(error)
                    if isDatabasePasswordError(error) {
                        return false
                    }
                }
            }
            refreshRulesFromDiskLocked()
            if rulesActiveLocked() {
                // The channel-aware equivalent of the merge below: the view is
                // rebuilt from the channels as they now stand, which is what
                // the reference engine reads at the top of every mutation.
                try loadChannelsFromDiskLocked()
                assembleViewLocked()
                return true
            }
            clearChannelStateLocked()
            _ = try SyncConflictResolver.resolveDatabaseConflicts(databaseURL: databaseURL, password: password)
            let latest = try loadDatabaseWithPasswordLocked()
            SyncConflictResolver.merge(into: &database, source: latest)
            SyncConflictResolver.normalize(&database)
            return true
        } catch {
            DispatchQueue.main.async { self.delegate?.clipStoreDidFail(error: error) }
            return false
        }
    }

    @discardableResult
    private func saveLocked() -> Bool {
        guard rulesActiveLocked(), !channelSlots.isEmpty else {
            return legacySaveLocked()
        }
        return saveWithChannelsLocked()
    }

    @discardableResult
    private func legacySaveLocked() -> Bool {
        do {
            SyncConflictResolver.normalize(&database)
            database.UpdatedUnixMs = TimeUtil.nowUnixMs()
            try ClipDatabaseFile.saveAtomic(databaseURL, database: database, password: password)
            if shouldAttemptSynchronousServerRequestLocked() {
                do {
                    try uploadToServerLocked()
                } catch {
                    serverUploadPending = true
                    markServerFailureLocked()
                    reportServerFailureLocked(error)
                    if isDatabasePasswordError(error) {
                        return false
                    }
                }
            } else if serverClient != nil {
                serverUploadPending = true
            }
            resetWatcherLocked()
            return true
        } catch {
            DispatchQueue.main.async { self.delegate?.clipStoreDidFail(error: error) }
            return false
        }
    }

    // MARK: - Sync channels

    /// The public surface the sync-rules editor uses.
    func getSyncRules() -> SyncRulesDocument? {
        queue.sync { rulesDocument }
    }

    func syncRulesReadOnly() -> Bool {
        queue.sync { SyncRuleEngine.isReadOnly(rulesDocument) }
    }

    /// The channels this device downloads, or nil when it downloads everything.
    /// The editor uses it to disable removing a channel it cannot see.
    func syncSubscribedChannelKeys() -> [String]? {
        queue.sync { SyncRuleEngine.subscribedChannels(document: rulesDocument, deviceName: machineName) }
    }

    func syncRulesDeviceName() -> String {
        queue.sync { machineName }
    }

    /// Validates and applies an edited rules document. A validation problem is
    /// returned immediately; the re-route and upload it triggers run on the
    /// store queue and report failures through `clipStoreDidFail`. Returning
    /// synchronously here would deadlock, because applying rules can ask the
    /// main thread for the history password.
    func setSyncRules(_ document: SyncRulesDocument) -> String? {
        if let reason = SyncRuleEngine.validate(document) { return reason }
        if let reason = queue.sync(execute: { syncRulesRefusalLocked(document) }) { return reason }
        queue.async { self.applySyncRulesLocked(document) }
        return nil
    }

    /// Spec section 5, "Rules edits": editors must be subscribed to every
    /// channel an edit affects, because the re-route below can only move
    /// entries this device can actually see. The comparison is against the
    /// document in effect now, not the candidate.
    private func syncRulesRefusalLocked(_ next: SyncRulesDocument) -> String? {
        if SyncRuleEngine.isReadOnly(rulesDocument) {
            return "These sync rules were written by a newer version of Clipman, so this version can only display them."
        }
        guard let current = rulesDocument else { return nil }
        let currentKeys = SyncRuleEngine.allChannelKeys(current)
        guard !currentKeys.isEmpty else { return nil }
        guard let subscribed = SyncRuleEngine.subscribedChannels(document: current, deviceName: machineName) else {
            return nil
        }

        let surviving = Set(SyncRuleEngine.allChannelKeys(next))
        let downloaded = Set(subscribed)
        for key in currentKeys where !surviving.contains(key) && !downloaded.contains(key) {
            return "This device is not subscribed to the \(SyncRuleEngine.channelName(current, key: key)) channel and cannot see its entries. Subscribe to it before removing it."
        }
        return nil
    }

    private func applySyncRulesLocked(_ document: SyncRulesDocument) {
        guard !SyncRuleEngine.isReadOnly(rulesDocument) else { return }
        var updated = document
        updated.Clipman = SyncRuleEngine.documentKind
        updated.Version = SyncRuleEngine.currentVersion
        updated.UpdatedUnixMs = TimeUtil.nowUnixMs()
        updated.UpdatedBy = machineName

        // Spec section 5, "Channel deletion": the entries have to leave before
        // the document forgets where they live.
        guard rerouteChannelsLeavingDocumentLocked(updated) else {
            let failure = ClipDatabaseError.unsupportedFormat(
                "Clipman could not move the entries out of the sync channels being removed, so the new rules were not saved."
            )
            DispatchQueue.main.async { self.delegate?.clipStoreDidFail(error: failure) }
            return
        }

        rulesDocument = updated
        rebuildChannelSlotsLocked()
        writeRulesCacheLocked()
        publishRulesLocked(updated, createOnly: !rulesExistsOnServer)

        guard mergeLatestBeforeWriteLocked() else { return }
        let saved = saveLocked()
        DispatchQueue.main.async {
            if saved { self.delegate?.clipStoreDidChange() }
        }
    }

    /// Spec section 5, "Channel deletion": the editing client re-routes a
    /// departing channel's entries and uploads the affected channels before the
    /// document forgets the channel. The re-route runs under a transitional
    /// document that keeps the OLD channel list - so this device stays
    /// subscribed and can still see those entries - while carrying the new
    /// routes, with a route that is disappearing neutralized so its entries fall
    /// through to whatever else matches, or to core. A rename is a removal of
    /// the old key plus an addition of the new one and takes the same path.
    /// Returns false when the transitional save could not be committed, in which
    /// case the edit must not be published.
    private func rerouteChannelsLeavingDocumentLocked(_ next: SyncRulesDocument) -> Bool {
        guard rulesActiveLocked(), !channelSlots.isEmpty, let current = rulesDocument else { return true }

        var surviving: [String: SyncRoute] = [:]
        for channel in next.Channels {
            let key = SyncRuleEngine.channelKey(channel.Name)
            if !key.isEmpty, surviving[key] == nil {
                surviving[key] = channel.Route
            }
        }

        var leaving = false
        var transitional = current
        for index in transitional.Channels.indices {
            let key = SyncRuleEngine.channelKey(transitional.Channels[index].Name)
            if let replacement = surviving[key] {
                transitional.Channels[index].Route = replacement
                continue
            }
            // This channel is going away: a route with no condition never
            // matches, so its residents fall through the remaining rules and the
            // two-phase upload empties the channel under gain-before-lose.
            transitional.Channels[index].Route = SyncRoute()
            leaving = true
        }
        guard leaving else { return true }

        let previous = rulesDocument
        rulesDocument = transitional
        let committed = mergeLatestBeforeWriteLocked() && saveLocked()
        rulesDocument = previous
        return committed
    }

    /// True when a rules document is in effect and defines at least one usable
    /// channel. Everything channel-aware in this file is guarded on this, so a
    /// client with no rules, or with rules disabled, behaves exactly as it did
    /// before the feature existed (spec section 7).
    private func rulesActiveLocked() -> Bool {
        guard let document = rulesDocument, document.Enabled else { return false }
        return !SyncRuleEngine.allChannelKeys(document).isEmpty
    }

    private func clearChannelStateLocked() {
        channelSlots = []
        residence = [:]
        viewMarkers = [:]
    }

    private var dataFolderURL: URL {
        databaseURL.deletingLastPathComponent()
    }

    private func channelFileURL(_ key: String) -> URL {
        dataFolderURL.appendingPathComponent(SyncRuleEngine.channelFileName(key))
    }

    private var rulesFileURL: URL {
        dataFolderURL.appendingPathComponent(SyncRuleEngine.syncRulesFileName)
    }

    private var pendingChannelWritesURL: URL {
        dataFolderURL.appendingPathComponent(SyncRuleEngine.pendingChannelWritesFileName)
    }

    /// A channel blob created for the first time copies the core database's
    /// salt, so one PBKDF2 derivation serves every channel (spec section 5).
    private func coreSaltLocked() -> [UInt8]? {
        ClipDatabaseFile.containerSalt(databaseURL)
    }

    private func channelClientLocked(_ slot: ChannelSlot) -> ServerStorageClient? {
        guard let client = serverClient, client.isConfigured else { return nil }
        if slot.key.isEmpty { return client }
        return client.addressing(databaseID: slot.databaseID)
    }

    /// Rebuilds the core-first slot list from the current subscriptions,
    /// carrying forward what each surviving channel already knows.
    private func rebuildChannelSlotsLocked() {
        let existing = channelSlots
        var slots: [ChannelSlot] = []

        var core = existing.first { $0.key.isEmpty }
            ?? ChannelSlot(key: "", url: databaseURL, databaseID: "")
        core.url = databaseURL
        slots.append(core)

        for key in SyncRuleEngine.subscribedKeys(document: rulesDocument, deviceName: machineName) {
            let databaseID = serverClient == nil
                ? ""
                : ServerDatabaseIdentity.channelDatabaseId(token: serverToken, password: password, channelKey: key)
            // In server mode a channel that cannot be addressed is left out of
            // the view; entries bound for it are written through instead.
            if serverClient != nil && databaseID.isEmpty { continue }
            if var slot = existing.first(where: { $0.key == key }) {
                slot.url = channelFileURL(key)
                slot.databaseID = databaseID
                slots.append(slot)
            } else {
                slots.append(ChannelSlot(key: key, url: channelFileURL(key), databaseID: databaseID))
            }
        }
        channelSlots = slots
    }

    private func loadSlotDatabaseLocked(_ slot: ChannelSlot) throws -> ClipDatabase {
        if slot.key.isEmpty {
            _ = try SyncConflictResolver.resolveDatabaseConflicts(databaseURL: slot.url, password: password)
            return try loadDatabaseWithPasswordLocked()
        }
        try resolveChannelFileConflictsLocked(slot.url)
        return try ClipDatabaseFile.load(slot.url, password: password)
    }

    /// Conflict-copy resolution for a channel file. The generic resolver cannot
    /// be used unfiltered here: spec section 2 turns spaces into dashes, so the
    /// file of a channel named "work laptop" looks like a sync service's
    /// conflict copy of the channel named "work", and merging and deleting it
    /// would lose a whole channel. Any sibling that is itself a channel's
    /// storage file - whether or not this device's rules document still
    /// defines that channel - is therefore never treated as a conflict copy.
    private func resolveChannelFileConflictsLocked(_ url: URL) throws {
        let conflicts = SyncConflictResolver.conflictSiblings(for: url)
            .filter { !SyncRuleEngine.isChannelFileName($0.lastPathComponent) }
        guard !conflicts.isEmpty else { return }

        var merged = ClipDatabase()
        if FileManager.default.fileExists(atPath: url.path) {
            SyncConflictResolver.merge(into: &merged, source: try ClipDatabaseFile.load(url, password: password))
        }
        for conflict in conflicts {
            SyncConflictResolver.merge(into: &merged, source: try ClipDatabaseFile.load(conflict, password: password))
        }
        SyncConflictResolver.normalize(&merged)
        try ClipDatabaseFile.saveAtomic(url, database: merged, password: password, salt: coreSaltLocked())
        for conflict in conflicts {
            try? FileManager.default.removeItem(at: conflict)
        }
    }

    private func loadChannelsFromDiskLocked() throws {
        rebuildChannelSlotsLocked()
        for index in channelSlots.indices {
            var loaded = try loadSlotDatabaseLocked(channelSlots[index])
            SyncConflictResolver.normalize(&loaded)
            channelSlots[index].database = loaded
            channelSlots[index].fetched = Self.entriesByComparableID(loaded.Entries)
            // In shared-folder mode the file is the transport, so its content is
            // the hash recorded at the last transfer. In server mode only a
            // transfer may replace that hash; an empty hash means "dirty", which
            // is the safe answer when this device has not talked to the server
            // about this channel yet.
            if serverClient == nil {
                channelSlots[index].plainHash = Self.durableHash(loaded)
            }
        }
    }

    /// Spec section 5, download steps 3 and 4: merges the channels into the one
    /// view the user sees and records which channel each entry came from.
    private func assembleViewLocked() {
        var view = ClipDatabase(Version: 1, UpdatedUnixMs: TimeUtil.nowUnixMs(), Entries: [], DeletedEntries: [])
        var owners: [String] = []
        var indexByID: [String: Int] = [:]

        for slot in channelSlots {
            if slot.database.Version > view.Version {
                view.Version = slot.database.Version
            }
            if slot.key.isEmpty {
                view.unknownFields = slot.database.unknownFields
            }
            for entry in slot.database.Entries {
                let identifier = Self.comparableID(entry.Id)
                if !identifier.isEmpty, let index = indexByID[identifier] {
                    // The same id in two channels is a move race: the copy with
                    // the higher ModifiedUnixMs wins and the loser is dropped,
                    // to be repaired by the next save.
                    if entry.ModifiedUnixMs > view.Entries[index].ModifiedUnixMs {
                        view.Entries[index] = entry
                        owners[index] = slot.key
                    }
                    continue
                }
                view.Entries.append(entry)
                owners.append(slot.key)
                if !identifier.isEmpty {
                    indexByID[identifier] = view.Entries.count - 1
                }
            }
        }

        // Tombstones apply within their own channel only, with one exception: a
        // marker with a non-empty TextHash also suppresses matching text in
        // other channels. A relocation marker has an empty TextHash and so can
        // never suppress a live entry elsewhere.
        var suppressed = [Bool](repeating: false, count: view.Entries.count)
        for slot in channelSlots {
            for marker in slot.database.DeletedEntries where !marker.TextHash.isEmpty {
                for index in view.Entries.indices where !suppressed[index] && owners[index] != slot.key {
                    if Self.textMarkerSuppresses(marker, view.Entries[index]) {
                        suppressed[index] = true
                    }
                }
            }
        }

        var survivors: [ClipEntry] = []
        var owner: [String: String] = [:]
        var live = Set<String>()
        for (index, entry) in view.Entries.enumerated() where !suppressed[index] {
            survivors.append(entry)
            owner[entry.Id] = owners[index]
            live.insert(Self.comparableID(entry.Id))
        }
        view.Entries = survivors

        // The view carries every channel's markers, except those contradicted by
        // a live entry elsewhere: applying a relocation marker to the view would
        // delete the entry it only meant to move.
        for slot in channelSlots {
            for marker in slot.database.DeletedEntries where !live.contains(Self.comparableID(marker.Id)) {
                view.DeletedEntries.append(marker)
            }
        }
        SyncConflictResolver.normalize(&view)

        var finalResidence: [String: String] = [:]
        for entry in view.Entries {
            if let key = owner[entry.Id] {
                finalResidence[entry.Id] = key
            }
        }
        database = view
        residence = finalResidence
        viewMarkers = Self.markersByComparableID(view.DeletedEntries)
    }

    /// The HEAD sweep of spec section 5, download step 2, used on its own to
    /// decide whether a poll has any work to do. Without it a client with rules
    /// enabled would rebuild its whole view every two seconds.
    private func channelRevisionsChangedLocked() -> Bool {
        guard rulesActiveLocked() else { return false }
        guard !channelSlots.isEmpty else { return true }
        for slot in channelSlots where !slot.key.isEmpty {
            guard let client = channelClientLocked(slot) else { continue }
            if slot.plainHash.isEmpty { return true }
            do {
                let head = try client.metadata()
                if head.revision != slot.revision || !slot.existsOnServer { return true }
            } catch ServerStorageError.notFound {
                if slot.existsOnServer { return true }
            } catch {
                return true
            }
        }
        return false
    }

    /// Spec section 5, download steps 1 and 2 for server mode: the rules bucket
    /// has already been checked by the caller; each subscribed channel is HEADed
    /// and only downloaded when its revision moved.
    private func syncChannelsFromServerLocked() throws {
        rebuildChannelSlotsLocked()
        for index in channelSlots.indices {
            var slot = channelSlots[index]
            var merged = try loadSlotDatabaseLocked(slot)
            SyncConflictResolver.normalize(&merged)
            let fileHash = Self.durableHash(merged)
            // The baseline is what the transport holds, never what the local
            // file holds: an empty baseline means "dirty", which is the safe
            // answer whenever this device has not transferred this channel yet.
            var baselineHash = slot.plainHash

            if let channelClient = channelClientLocked(slot) {
                do {
                    let head = try channelClient.metadata()
                    if head.revision != slot.revision || !slot.existsOnServer {
                        let download = try channelClient.download()
                        var remote = try loadDownloadedDatabaseLocked(download.data)
                        SyncConflictResolver.normalize(&remote)
                        baselineHash = Self.durableHash(remote)
                        SyncConflictResolver.merge(into: &merged, source: remote)
                        SyncConflictResolver.normalize(&merged)
                        slot.revision = download.metadata.revision
                    }
                    slot.existsOnServer = true
                } catch ServerStorageError.notFound {
                    // A missing bucket is an empty channel, not an error, and it
                    // hashes like one: a channel nobody has written to yet must
                    // not be created just because this device subscribes to it.
                    slot.existsOnServer = false
                    slot.revision = ""
                    baselineHash = Self.emptyDatabaseHash()
                }
            } else {
                baselineHash = fileHash
            }

            slot.database = merged
            slot.plainHash = baselineHash
            slot.fetched = Self.entriesByComparableID(merged.Entries)
            channelSlots[index] = slot
            if slot.key.isEmpty {
                serverRevision = slot.revision
            }
            if Self.durableHash(merged) != fileHash {
                try ClipDatabaseFile.saveAtomic(
                    slot.url,
                    database: merged,
                    password: password,
                    salt: slot.key.isEmpty ? nil : coreSaltLocked()
                )
            }
        }

        assembleViewLocked()
        resetWatcherLocked()
        let dirty = channelSlots.contains { Self.isDirty($0, Self.durableHash($0.database)) }
        if dirty {
            _ = saveWithChannelsLocked()
            return
        }
        serverUploadPending = false
        markServerSuccessLocked(upload: false)
    }

    /// Spec section 5, upload steps 1 to 5. Routes every entry, rebuilds one
    /// database per channel, writes entries bound for unsubscribed channels
    /// straight through, and commits the channels whose plaintext changed - in
    /// two phases, so a partial failure can leave an entry in two channels but
    /// never in none.
    @discardableResult
    private func saveWithChannelsLocked() -> Bool {
        let now = TimeUtil.nowUnixMs()
        SyncConflictResolver.normalize(&database)
        database.UpdatedUnixMs = now

        var slotIndexByKey: [String: Int] = [:]
        for (index, slot) in channelSlots.enumerated() {
            slotIndexByKey[slot.key] = index
        }

        var routed: [String: [ClipEntry]] = [:]
        var departures: [String: [ClipEntry]] = [:]
        var relocations: [String: [DeletedClipEntry]] = [:]
        var pending: [String: [ClipEntry]] = [:]
        var pendingKeys: [String] = []

        for entry in database.Entries {
            let target = SyncRuleEngine.target(document: rulesDocument, entry: entry, residence: residence[entry.Id])
            if let source = residence[entry.Id], source != target {
                departures[source, default: []].append(entry)
                relocations[source, default: []].append(DeletedClipEntry(
                    Id: entry.Id,
                    TextHash: "",
                    DeletedUnixMs: now,
                    SourceMachine: machineName
                ))
            }
            if slotIndexByKey[target] != nil {
                routed[target, default: []].append(entry)
                continue
            }
            if pending[target] == nil {
                pendingKeys.append(target)
            }
            pending[target, default: []].append(entry)
        }

        // Tombstones are channel-local: each channel keeps the markers it
        // already carried, and only markers this mutation created or refreshed
        // are filed against the channel the entry lived in.
        func assembleMarkers(includingRelocations: Bool) -> [String: [DeletedClipEntry]] {
            var markers: [String: [DeletedClipEntry]] = [:]
            for slot in self.channelSlots {
                markers[slot.key] = slot.database.DeletedEntries
            }
            for marker in self.database.DeletedEntries {
                let identifier = Self.comparableID(marker.Id)
                if let before = self.viewMarkers[identifier],
                   before.DeletedUnixMs == marker.DeletedUnixMs,
                   before.TextHash == marker.TextHash {
                    continue
                }
                var home = self.residence[marker.Id] ?? ""
                if slotIndexByKey[home] == nil { home = "" }
                markers[home, default: []].append(marker)
            }
            if includingRelocations {
                for (key, relocated) in relocations where slotIndexByKey[key] != nil {
                    markers[key, default: []].append(contentsOf: relocated)
                }
            }
            return markers
        }

        func buildDatabases(_ assignment: [String: [ClipEntry]], _ markers: [String: [DeletedClipEntry]]) -> [ClipDatabase] {
            self.channelSlots.map { slot in
                let entries = assignment[slot.key] ?? []
                var built = ClipDatabase(
                    Version: max(1, slot.database.Version),
                    UpdatedUnixMs: now,
                    Entries: entries,
                    DeletedEntries: Self.dropMarkersForEntries(markers[slot.key] ?? [], entries),
                    unknownFields: slot.key.isEmpty ? self.database.unknownFields : slot.database.unknownFields
                )
                SyncConflictResolver.normalize(&built)
                built.UpdatedUnixMs = now
                return built
            }
        }

        // Phase one keeps the entries a channel is about to lose, in the copy
        // the channel was fetched with, and withholds its new relocation
        // markers, so the first pass only ever adds.
        func withDepartures(_ assignment: [String: [ClipEntry]]) -> [String: [ClipEntry]] {
            guard !departures.isEmpty else { return assignment }
            var combined = assignment
            for (key, leaving) in departures where !leaving.isEmpty {
                guard let index = slotIndexByKey[key] else { continue }
                var staying = combined[key] ?? []
                for entry in leaving {
                    staying.append(self.channelSlots[index].fetched[Self.comparableID(entry.Id)] ?? entry)
                }
                combined[key] = staying
            }
            return combined
        }

        var writeThroughFailed = false
        var delivered: [String] = []

        // Write-through comes first: its targets gain entries that their source
        // channels are about to lose. When one fails the entry is not taken
        // away from where it already lives - its relocation is cancelled - and
        // it is parked for the next successful poll (spec section 6).
        for key in pendingKeys.sorted() {
            let entries = pending[key] ?? []
            do {
                try writeThroughLocked(key: key, entries: entries)
                delivered.append(SyncRuleEngine.channelName(rulesDocument, key: key))
                dropPendingChannelWritesLocked(key: key, entries: entries)
            } catch {
                writeThroughFailed = true
                RuntimeLogger.write(
                    "Clipman could not deliver entries to an unsubscribed sync channel.",
                    error: error,
                    details: "Channel: \(key)"
                )
                parkPendingChannelWritesLocked(key: key, entries: entries)
                for entry in entries {
                    guard let source = residence[entry.Id] else { continue }
                    routed[source, default: []].append(entry)
                    departures[source] = Self.removingEntry(departures[source] ?? [], id: entry.Id)
                    relocations[source] = Self.removingMarker(relocations[source] ?? [], id: entry.Id)
                }
            }
        }

        var uploadError: Error?
        var committedAny = false

        let phaseOne = buildDatabases(withDepartures(routed), assembleMarkers(includingRelocations: false))
        for index in channelSlots.indices {
            let candidate = Self.durableHash(phaseOne[index])
            guard Self.isDirty(channelSlots[index], candidate) else { continue }
            do {
                try commitChannelLocked(index: index, database: phaseOne[index], hash: candidate)
                committedAny = true
            } catch {
                uploadError = error
                break
            }
        }

        // Phase two runs only after every addition committed: the losing
        // channels drop their departures and gain their relocation markers.
        if uploadError == nil {
            let phaseTwo = buildDatabases(routed, assembleMarkers(includingRelocations: true))
            for index in channelSlots.indices {
                guard !(departures[channelSlots[index].key] ?? []).isEmpty else { continue }
                let candidate = Self.durableHash(phaseTwo[index])
                guard Self.isDirty(channelSlots[index], candidate) else { continue }
                do {
                    try commitChannelLocked(index: index, database: phaseTwo[index], hash: candidate)
                    committedAny = true
                } catch {
                    uploadError = error
                    break
                }
            }
        }

        assembleViewLocked()
        resetWatcherLocked()
        announceWriteThroughLocked(delivered)

        if let uploadError {
            // A channel upload failed, so part of this mutation is not stored.
            // Reporting it as saved would lose the user's change.
            serverUploadPending = serverClient != nil
            markServerFailureLocked()
            reportServerFailureLocked(uploadError)
            return false
        }
        if writeThroughFailed {
            // Every subscribed channel committed; only the parked entries are
            // outstanding, so the mutation itself succeeded.
            serverUploadPending = serverClient != nil
            return true
        }
        serverUploadPending = false
        markServerSuccessLocked(upload: committedAny && serverClient != nil)
        return true
    }

    /// Writes one channel: the local file first, which is the shared-folder
    /// transport and the server-mode cache, then the identical bytes to its
    /// bucket. A conflict re-reads that bucket, merges and retries.
    private func commitChannelLocked(index: Int, database candidate: ClipDatabase, hash: Data) throws {
        let key = channelSlots[index].key
        let url = channelSlots[index].url
        // The local file is written first: in shared-folder mode it IS the
        // transport, and in server mode it is the cache the bytes are uploaded
        // from, so the two can never disagree.
        try ClipDatabaseFile.saveAtomic(
            url,
            database: candidate,
            password: password,
            salt: key.isEmpty ? nil : coreSaltLocked()
        )

        guard let client = channelClientLocked(channelSlots[index]) else {
            // Shared-folder mode: the write above is the transfer.
            recordChannelTransferLocked(index: index, database: candidate, hash: hash)
            return
        }
        let data = try Data(contentsOf: url)
        do {
            let metadata = try client.upload(
                data: data,
                expectedRevision: channelSlots[index].revision,
                createOnly: !channelSlots[index].existsOnServer
            )
            recordChannelTransferLocked(index: index, database: candidate, hash: hash)
            channelSlots[index].revision = metadata.revision
            channelSlots[index].existsOnServer = true
            if key.isEmpty { serverRevision = metadata.revision }
        } catch ServerStorageError.conflict {
            try resolveChannelConflictLocked(index: index, database: candidate)
        } catch ServerStorageError.notFound {
            let metadata = try client.upload(data: data, expectedRevision: "")
            recordChannelTransferLocked(index: index, database: candidate, hash: hash)
            channelSlots[index].revision = metadata.revision
            channelSlots[index].existsOnServer = true
            if key.isEmpty { serverRevision = metadata.revision }
        }
    }

    /// Records the content and hash of what the transport now holds. It must
    /// only ever run after the transfer succeeded: recording it first would let
    /// a failed upload look clean on the next poll, so the change would be
    /// reported as synchronized while it had never reached the server. A slot
    /// left un-recorded is stale only until the next read, which reloads the
    /// file and finds it dirty against the last real transfer, so the upload is
    /// retried. Mirrors the reference engine's putChannel.
    private func recordChannelTransferLocked(index: Int, database candidate: ClipDatabase, hash: Data) {
        channelSlots[index].database = candidate
        channelSlots[index].plainHash = hash
        channelSlots[index].fetched = Self.entriesByComparableID(candidate.Entries)
    }

    private func resolveChannelConflictLocked(index: Int, database candidate: ClipDatabase) throws {
        guard let client = channelClientLocked(channelSlots[index]) else { return }
        let key = channelSlots[index].key
        let url = channelSlots[index].url
        var local = candidate

        for _ in 0..<3 {
            var fresh = ClipDatabase()
            var revision = ""
            do {
                let download = try client.download()
                fresh = try loadDownloadedDatabaseLocked(download.data)
                revision = download.metadata.revision
            } catch ServerStorageError.notFound {
                fresh = ClipDatabase()
                revision = ""
            }
            var combined = fresh
            SyncConflictResolver.merge(into: &combined, source: local)
            SyncConflictResolver.normalize(&combined)
            combined.UpdatedUnixMs = TimeUtil.nowUnixMs()
            try ClipDatabaseFile.saveAtomic(
                url,
                database: combined,
                password: password,
                salt: key.isEmpty ? nil : coreSaltLocked()
            )
            let data = try Data(contentsOf: url)
            do {
                let metadata = try client.upload(
                    data: data,
                    expectedRevision: revision,
                    createOnly: revision.isEmpty
                )
                recordChannelTransferLocked(index: index, database: combined, hash: Self.durableHash(combined))
                channelSlots[index].revision = metadata.revision
                channelSlots[index].existsOnServer = true
                if key.isEmpty { serverRevision = metadata.revision }
                return
            } catch ServerStorageError.conflict {
                local = combined
            }
        }
        throw ServerStorageError.conflict
    }

    /// The one-shot fetch-merge-put of spec section 6 for a channel this device
    /// does not subscribe to. The channel is discarded again afterwards, so its
    /// contents never reach the local view.
    private func writeThroughLocked(key: String, entries: [ClipEntry]) throws {
        guard !key.isEmpty, !entries.isEmpty else { return }

        guard let client = serverClient, client.isConfigured else {
            // Shared-folder mode: the channel is an ordinary sibling file and
            // writing it is the delivery.
            let url = channelFileURL(key)
            try resolveChannelFileConflictsLocked(url)
            var existing = try ClipDatabaseFile.load(url, password: password)
            existing.DeletedEntries = Self.dropMarkersForEntries(existing.DeletedEntries, entries)
            SyncConflictResolver.merge(into: &existing, source: ClipDatabase(Entries: entries))
            SyncConflictResolver.normalize(&existing)
            try ClipDatabaseFile.saveAtomic(url, database: existing, password: password, salt: coreSaltLocked())
            return
        }

        let databaseID = ServerDatabaseIdentity.channelDatabaseId(token: serverToken, password: password, channelKey: key)
        guard let channelClient = client.addressing(databaseID: databaseID) else {
            throw ServerStorageError.notConfigured
        }
        let temporary = dataFolderURL.appendingPathComponent(".clipman-write-through-\(UUID().uuidString).clipdb")
        defer { try? FileManager.default.removeItem(at: temporary) }

        for _ in 0..<3 {
            var existing = ClipDatabase()
            var revision = ""
            var exists = false
            do {
                let download = try channelClient.download()
                existing = try loadDownloadedDatabaseLocked(download.data)
                revision = download.metadata.revision
                exists = true
            } catch ServerStorageError.notFound {
                existing = ClipDatabase()
            }
            existing.DeletedEntries = Self.dropMarkersForEntries(existing.DeletedEntries, entries)
            SyncConflictResolver.merge(into: &existing, source: ClipDatabase(Entries: entries))
            SyncConflictResolver.normalize(&existing)
            try ClipDatabaseFile.saveAtomic(temporary, database: existing, password: password, salt: coreSaltLocked())
            let data = try Data(contentsOf: temporary)
            do {
                _ = try channelClient.upload(data: data, expectedRevision: revision, createOnly: !exists)
                return
            } catch ServerStorageError.conflict {
                continue
            }
        }
        throw ServerStorageError.conflict
    }

    private func parkPendingChannelWritesLocked(key: String, entries: [ClipEntry]) {
        var stored = pendingChannelWrites[key] ?? []
        for entry in entries where !stored.contains(where: { Self.comparableID($0.Id) == Self.comparableID(entry.Id) }) {
            stored.append(entry)
        }
        pendingChannelWrites[key] = stored
        persistPendingChannelWritesLocked()
    }

    private func dropPendingChannelWritesLocked(key: String, entries: [ClipEntry]) {
        guard var stored = pendingChannelWrites[key] else { return }
        let delivered = Set(entries.map { Self.comparableID($0.Id) })
        stored.removeAll { delivered.contains(Self.comparableID($0.Id)) }
        if stored.isEmpty {
            pendingChannelWrites.removeValue(forKey: key)
        } else {
            pendingChannelWrites[key] = stored
        }
        persistPendingChannelWritesLocked()
    }

    private func persistPendingChannelWritesLocked() {
        let url = pendingChannelWritesURL
        guard !pendingChannelWrites.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let value = PendingChannelWrites(Channels: pendingChannelWrites.keys.sorted().map {
            PendingChannelWrite(ChannelKey: $0, Entries: pendingChannelWrites[$0] ?? [])
        })
        do {
            try ClipDatabaseFile.saveAtomicCodable(url, value: value, password: password, salt: coreSaltLocked())
        } catch {
            RuntimeLogger.write("Clipman could not store pending sync channel writes.", error: error)
        }
    }

    private func loadPendingChannelWritesLocked() {
        var loaded: [String: [ClipEntry]] = [:]
        if let stored = try? ClipDatabaseFile.loadCodable(
            pendingChannelWritesURL,
            password: password,
            defaultValue: PendingChannelWrites()
        ) {
            for channel in stored.Channels where !channel.ChannelKey.isEmpty && !channel.Entries.isEmpty {
                loaded[channel.ChannelKey] = channel.Entries
            }
        }
        pendingChannelWrites = loaded
    }

    /// Retries parked write-throughs after a successful poll. Each entry is
    /// re-routed against the rules document in effect now, never against the
    /// channel key it was parked under, and an entry that now belongs to a
    /// subscribed channel simply rejoins the view.
    private func retryPendingChannelWritesLocked() {
        guard !pendingChannelWrites.isEmpty else { return }
        let parked = pendingChannelWrites.keys.sorted().flatMap { pendingChannelWrites[$0] ?? [] }
        guard !parked.isEmpty else {
            pendingChannelWrites = [:]
            persistPendingChannelWritesLocked()
            return
        }

        let subscribed = Set(channelSlots.map(\.key))
        var regrouped: [String: [ClipEntry]] = [:]
        var reclaimed: [ClipEntry] = []
        for entry in parked {
            let target = SyncRuleEngine.route(document: rulesDocument, entry: entry)
            if subscribed.contains(target) {
                reclaimed.append(entry)
                continue
            }
            regrouped[target, default: []].append(entry)
        }

        var remaining: [String: [ClipEntry]] = [:]
        var delivered: [String] = []
        for key in regrouped.keys.sorted() {
            let entries = regrouped[key] ?? []
            do {
                try writeThroughLocked(key: key, entries: entries)
                delivered.append(SyncRuleEngine.channelName(rulesDocument, key: key))
            } catch {
                remaining[key] = entries
            }
        }
        pendingChannelWrites = remaining
        persistPendingChannelWritesLocked()
        announceWriteThroughLocked(delivered)

        guard !reclaimed.isEmpty else { return }
        for entry in reclaimed where !database.Entries.contains(where: { Self.comparableID($0.Id) == Self.comparableID(entry.Id) }) {
            database.Entries.append(entry)
        }
        if saveLocked() {
            DispatchQueue.main.async { self.delegate?.clipStoreDidChange() }
        }
    }

    private func announceWriteThroughLocked(_ names: [String]) {
        guard !names.isEmpty else { return }
        var seen = Set<String>()
        let ordered = names.filter { seen.insert($0).inserted }
        DispatchQueue.main.async { self.delegate?.clipStoreDidWriteThrough(channelNames: ordered) }
    }

    private func afterSuccessfulPollLocked() {
        retryPendingRulesUploadLocked()
        selfRegisterDeviceLocked()
        retryPendingChannelWritesLocked()
    }

    /// Spec section 4, Registry behavior: once rules are enabled, a client whose
    /// device name is missing from Devices adds itself, subscribed to
    /// everything, on its next successful sync.
    private func selfRegisterDeviceLocked() {
        guard let document = rulesDocument, document.Enabled, !SyncRuleEngine.isReadOnly(document) else { return }
        let name = machineName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let target = SyncRuleEngine.normalized(name)
        guard !document.Devices.contains(where: { SyncRuleEngine.normalized($0.Name) == target }) else { return }

        var updated = document
        updated.Devices.append(SyncDevice(Name: name, Channels: ["*"]))
        updated.UpdatedUnixMs = TimeUtil.nowUnixMs()
        updated.UpdatedBy = name
        guard SyncRuleEngine.validate(updated) == nil else { return }
        rulesDocument = updated
        rebuildChannelSlotsLocked()
        writeRulesCacheLocked()
        publishRulesLocked(updated, createOnly: !rulesExistsOnServer)
    }

    /// Reads the rules document from its sibling file. That file is the
    /// shared-folder transport and, in server mode, the local cache the spec's
    /// 404 fallback restores from.
    @discardableResult
    private func refreshRulesFromDiskLocked() -> Bool {
        resolveRulesConflictsLocked()
        guard let payload = try? ClipDatabaseFile.loadRawPayload(rulesFileURL, password: password),
              let stored = SyncRuleEngine.parse(payload) else {
            // Nothing readable on disk: the cache must be written again from
            // whatever is in effect rather than assumed to be already there.
            rulesCacheHash = Data()
            return false
        }
        rulesCacheHash = Self.payloadHash(SyncRuleEngine.serialize(stored))
        let merged = SyncRuleEngine.merge(local: rulesDocument, remote: stored)
        guard merged != rulesDocument else { return false }
        rulesDocument = merged
        rebuildChannelSlotsLocked()
        return true
    }

    /// Spec section 5, download step 1: HEAD the rules bucket, download only on
    /// a revision change, merge into the cache, and recompute subscriptions. A
    /// damaged or unreadable rules document degrades to no rules rather than
    /// stopping history from syncing.
    @discardableResult
    private func refreshRulesFromServerLocked() -> Bool {
        guard let client = serverClient, client.isConfigured else { return false }
        let rulesID = ServerDatabaseIdentity.syncRulesDatabaseId(token: serverToken, password: password)
        guard let rulesClient = client.addressing(databaseID: rulesID) else { return false }

        do {
            let head = try rulesClient.metadata()
            rulesExistsOnServer = true
            if head.revision == rulesServerRevision, rulesDocument != nil {
                return false
            }
            let download = try rulesClient.download()
            rulesServerRevision = download.metadata.revision
            guard let payload = try? decodeRulesPayloadLocked(download.data),
                  let remote = SyncRuleEngine.parse(payload) else {
                return false
            }
            let merged = SyncRuleEngine.merge(local: rulesDocument, remote: remote)
            let changed = merged != rulesDocument
            // When the cache wins the merge, the effective document is not the
            // one the server holds, so no revision is reported: an If-Match
            // against it would claim an edit was based on a document the server
            // never saw.
            rulesRevision = (merged == remote) ? download.metadata.revision : ""
            rulesDocument = merged
            if changed {
                writeRulesCacheLocked()
                rebuildChannelSlotsLocked()
            }
            return changed
        } catch ServerStorageError.notFound {
            rulesExistsOnServer = false
            rulesRevision = ""
            rulesServerRevision = ""
            // A cached future-version document is kept for display only and must
            // never be re-uploaded, so it does not arm this fallback.
            guard let cached = rulesDocument, !SyncRuleEngine.isReadOnly(cached) else { return false }
            publishRulesLocked(cached, createOnly: true)
            return false
        } catch {
            return false
        }
    }

    private func decodeRulesPayloadLocked(_ data: Data) throws -> Data {
        let temporary = dataFolderURL.appendingPathComponent(".clipman-sync-rules-download-\(UUID().uuidString).clipdb")
        try FileManager.default.createDirectory(at: dataFolderURL, withIntermediateDirectories: true)
        try data.write(to: temporary, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let payload = try ClipDatabaseFile.loadRawPayload(temporary, password: password) else {
            throw ClipDatabaseError.unsupportedFormat("The sync rules document was empty.")
        }
        return payload
    }

    private func writeRulesCacheLocked() {
        guard let document = rulesDocument, let payload = SyncRuleEngine.serialize(document) else { return }
        let hash = Self.payloadHash(payload)
        guard hash != rulesCacheHash else { return }
        do {
            try ClipDatabaseFile.saveRawPayloadAtomic(
                rulesFileURL,
                payload: payload,
                password: password,
                salt: coreSaltLocked()
            )
            rulesCacheHash = hash
        } catch {
            RuntimeLogger.write("Clipman could not store the sync rules document.", error: error)
        }
    }

    /// Uploads the rules document and records the revision it committed at. A
    /// failure leaves both revisions untouched - folding `rulesServerRevision`
    /// forward on a failure would make the next poll believe it had already seen
    /// the server's copy - and arms `rulesUploadPending` so the poll retries.
    private func publishRulesLocked(_ document: SyncRulesDocument, createOnly: Bool) {
        guard serverClient != nil else { return }
        guard let revision = uploadRulesLocked(document, createOnly: createOnly) else {
            rulesUploadPending = true
            return
        }
        rulesUploadPending = false
        rulesRevision = revision
        rulesServerRevision = revision
    }

    private func retryPendingRulesUploadLocked() {
        guard rulesUploadPending,
              serverClient != nil,
              let document = rulesDocument,
              !SyncRuleEngine.isReadOnly(document) else {
            return
        }
        publishRulesLocked(document, createOnly: !rulesExistsOnServer)
    }

    /// Returns the committed revision, or nil when the upload failed.
    private func uploadRulesLocked(_ document: SyncRulesDocument, createOnly: Bool) -> String? {
        guard let client = serverClient, client.isConfigured else { return nil }
        let rulesID = ServerDatabaseIdentity.syncRulesDatabaseId(token: serverToken, password: password)
        guard let rulesClient = client.addressing(databaseID: rulesID),
              let payload = SyncRuleEngine.serialize(document) else {
            return nil
        }
        let temporary = dataFolderURL.appendingPathComponent(".clipman-sync-rules-upload-\(UUID().uuidString).clipdb")
        defer { resetWatcherLocked() }
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try ClipDatabaseFile.saveRawPayloadAtomic(
                temporary,
                payload: payload,
                password: password,
                salt: coreSaltLocked()
            )
            let data = try Data(contentsOf: temporary)
            let metadata = try rulesClient.upload(
                data: data,
                expectedRevision: createOnly ? "" : rulesRevision,
                createOnly: createOnly
            )
            rulesExistsOnServer = true
            return metadata.revision
        } catch {
            RuntimeLogger.write("Clipman could not upload the sync rules document.", error: error)
            return nil
        }
    }

    /// The rules file is not a `ClipDatabase`, so its conflict copies are merged
    /// by the document's own last-writer-wins rule rather than by the entry
    /// merge the history files use.
    private func resolveRulesConflictsLocked() {
        let conflicts = SyncConflictResolver.conflictSiblings(for: rulesFileURL)
        guard !conflicts.isEmpty else { return }

        var winner: SyncRulesDocument?
        if let payload = try? ClipDatabaseFile.loadRawPayload(rulesFileURL, password: password),
           let current = SyncRuleEngine.parse(payload) {
            winner = current
        }
        for conflict in conflicts {
            if let payload = try? ClipDatabaseFile.loadRawPayload(conflict, password: password),
               let candidate = SyncRuleEngine.parse(payload) {
                winner = SyncRuleEngine.merge(local: winner, remote: candidate)
            }
            try? FileManager.default.removeItem(at: conflict)
        }
        guard let winner, !SyncRuleEngine.isReadOnly(winner), let payload = SyncRuleEngine.serialize(winner) else {
            return
        }
        try? ClipDatabaseFile.saveRawPayloadAtomic(
            rulesFileURL,
            payload: payload,
            password: password,
            salt: coreSaltLocked()
        )
        rulesCacheHash = Self.payloadHash(payload)
    }

    // MARK: - Sync channel helpers

    /// The dirty-detection hash of spec section 5, upload step 4: SHA-256 of the
    /// deterministic plaintext JSON with the database-level `UpdatedUnixMs`
    /// zeroed. Zeroing it is what makes the hash durable across poll cycles,
    /// because normalization restamps that field on every pass. Sorted keys make
    /// the encoding deterministic; this hash is only ever compared with itself
    /// on the same device, so it needs no cross-client agreement.
    private static func durableHash(_ database: ClipDatabase) -> Data {
        var durable = database
        durable.UpdatedUnixMs = 0
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let encoded = try? encoder.encode(durable) else { return Data() }
        return Data(SHA256.hash(data: encoded))
    }

    /// The durable hash of an empty, normalized channel database.
    private static func emptyDatabaseHash() -> Data {
        var empty = ClipDatabase()
        SyncConflictResolver.normalize(&empty)
        return durableHash(empty)
    }

    private static func payloadHash(_ payload: Data?) -> Data {
        guard let payload else { return Data() }
        return Data(SHA256.hash(data: payload))
    }

    /// An empty hash on either side means "not known to match", which must be
    /// treated as dirty so nothing is silently left unsent.
    private static func isDirty(_ slot: ChannelSlot, _ candidate: Data) -> Bool {
        slot.plainHash.isEmpty || candidate.isEmpty || candidate != slot.plainHash
    }

    private static func comparableID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func entriesByComparableID(_ entries: [ClipEntry]) -> [String: ClipEntry] {
        var byID: [String: ClipEntry] = [:]
        for entry in entries {
            byID[comparableID(entry.Id)] = entry
        }
        return byID
    }

    private static func markersByComparableID(_ markers: [DeletedClipEntry]) -> [String: DeletedClipEntry] {
        var byID: [String: DeletedClipEntry] = [:]
        for marker in markers {
            byID[comparableID(marker.Id)] = marker
        }
        return byID
    }

    /// The text-hash half of the entry merge's deletion rule, which is the only
    /// tombstone rule that reaches across channel boundaries.
    private static func textMarkerSuppresses(_ marker: DeletedClipEntry, _ entry: ClipEntry) -> Bool {
        guard !marker.TextHash.isEmpty, !entry.Text.isEmpty else { return false }
        guard marker.TextHash.caseInsensitiveCompare(SyncConflictResolver.textHash(entry.Text)) == .orderedSame else {
            return false
        }
        let changed = max(entry.CreatedUnixMs, entry.LastUsedUnixMs)
        return marker.DeletedUnixMs <= 0 || changed <= marker.DeletedUnixMs
    }

    /// Removes markers naming an entry being written into the same channel.
    /// Without this a relocation marker left by an earlier move would delete the
    /// entry again when a rule change moves it back.
    private static func dropMarkersForEntries(_ markers: [DeletedClipEntry], _ entries: [ClipEntry]) -> [DeletedClipEntry] {
        guard !markers.isEmpty, !entries.isEmpty else { return markers }
        let resident = Set(entries.map { comparableID($0.Id) })
        return markers.filter { !resident.contains(comparableID($0.Id)) }
    }

    private static func removingEntry(_ entries: [ClipEntry], id: String) -> [ClipEntry] {
        let target = comparableID(id)
        return entries.filter { comparableID($0.Id) != target }
    }

    private static func removingMarker(_ markers: [DeletedClipEntry], id: String) -> [DeletedClipEntry] {
        let target = comparableID(id)
        return markers.filter { comparableID($0.Id) != target }
    }

    private func resetServerStatusLocked() {
        serverLastPollUnixMs = 0
        serverLastSuccessUnixMs = 0
        serverLastUploadUnixMs = 0
        serverNextPollUnixMs = 0
        serverConsecutiveFailures = 0
    }

    private func markServerSuccessLocked(upload: Bool) {
        let now = TimeUtil.nowUnixMs()
        serverLastSuccessUnixMs = now
        if upload {
            serverLastUploadUnixMs = now
        }
        serverConsecutiveFailures = 0
        serverNextPollUnixMs = 0
        if serverFailureReported {
            serverFailureReported = false
            DispatchQueue.main.async { self.delegate?.clipStoreServerSyncDidRecover() }
        }
    }

    private func markServerFailureLocked() {
        let now = TimeUtil.nowUnixMs()
        serverConsecutiveFailures = min(serverConsecutiveFailures + 1, 8)
        let delay = min(60, 2 << min(serverConsecutiveFailures, 5))
        serverNextPollUnixMs = now + Int64(delay * 1000)
        serverFailureReported = true
    }

    private func shouldAttemptSynchronousServerRequestLocked() -> Bool {
        serverClient != nil
            && !serverSyncInProgress
            && !serverPollInProgress
            && serverConsecutiveFailures == 0
    }

    private func reportServerFailureLocked(_ error: Error) {
        let reported: Error = isDatabasePasswordError(error) ? error : ServerSyncFailureError(underlying: error)
        DispatchQueue.main.async { self.delegate?.clipStoreDidFail(error: reported) }
    }

    private func startServerPollTimerLocked() {
        serverPollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2), leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.pollServerLocked()
        }
        serverPollTimer = timer
        timer.resume()
    }

    private func pollServerLocked() {
        guard let client = serverClient, client.isConfigured, !serverSyncInProgress, !serverPollInProgress else { return }
        let now = TimeUtil.nowUnixMs()
        if serverNextPollUnixMs > now { return }
        serverLastPollUnixMs = now
        serverPollInProgress = true
        let generation = serverConfigurationGeneration
        serverRequestQueue.async { [weak self] in
            let result = Result { try client.metadata() }
            self?.queue.async { [weak self] in
                guard let self, generation == self.serverConfigurationGeneration else { return }
                self.serverPollInProgress = false
                self.handleServerMetadataResultLocked(result)
            }
        }
    }

    private func handleServerMetadataResultLocked(_ result: Result<ServerDatabaseMetadata, Error>) {
        switch result {
        case .success(let metadata):
            // Spec section 5, download step 1: the rules bucket is checked
            // first, because its content decides which channels are read next.
            let rulesChanged = refreshRulesFromServerLocked()
            let revisionChanged = metadata.revision != serverRevision
            guard revisionChanged || serverUploadPending || rulesChanged || channelRevisionsChangedLocked() else {
                markServerSuccessLocked(upload: false)
                afterSuccessfulPollLocked()
                return
            }
            do {
                try syncFromServerLocked(uploadLocalWhenMissing: false, refreshRules: false)
                if revisionChanged || rulesChanged {
                    DispatchQueue.main.async { self.delegate?.clipStoreDidChange() }
                }
                afterSuccessfulPollLocked()
            } catch {
                markServerFailureLocked()
                reportServerFailureLocked(error)
                if isDatabasePasswordError(error) {
                    serverPollTimer?.cancel()
                    serverPollTimer = nil
                    serverClient = nil
                }
            }
        case .failure(ServerStorageError.notFound):
            do {
                try syncFromServerLocked(uploadLocalWhenMissing: true)
                DispatchQueue.main.async { self.delegate?.clipStoreDidChange() }
                afterSuccessfulPollLocked()
            } catch {
                markServerFailureLocked()
                reportServerFailureLocked(error)
                if isDatabasePasswordError(error) {
                    serverPollTimer?.cancel()
                    serverPollTimer = nil
                    serverClient = nil
                }
            }
        case .failure(let error):
            markServerFailureLocked()
            reportServerFailureLocked(error)
            if isDatabasePasswordError(error) {
                serverPollTimer?.cancel()
                serverPollTimer = nil
                serverClient = nil
            }
        }
    }

    private func syncFromServerLocked(uploadLocalWhenMissing: Bool, refreshRules: Bool = true) throws {
        guard let client = serverClient, client.isConfigured else { return }
        if serverSyncInProgress { return }
        serverSyncInProgress = true
        defer { serverSyncInProgress = false }

        if refreshRules {
            refreshRulesFromServerLocked()
        }
        if rulesActiveLocked() {
            try syncChannelsFromServerLocked()
            return
        }
        clearChannelStateLocked()

        do {
            let download = try client.download()
            let downloaded = try loadDownloadedDatabaseLocked(download.data)
            let uploadMerged = hasLocalStateMissingFromServer(server: downloaded, local: database)
            SyncConflictResolver.merge(into: &database, source: downloaded)
            SyncConflictResolver.normalize(&database)
            serverRevision = download.metadata.revision
            try ClipDatabaseFile.saveAtomic(databaseURL, database: database, password: password)
            resetWatcherLocked()
            if uploadMerged {
                let data = try Data(contentsOf: databaseURL)
                let metadata = try client.upload(data: data, expectedRevision: serverRevision)
                serverRevision = metadata.revision
                markServerSuccessLocked(upload: true)
            }
            serverUploadPending = false
            markServerSuccessLocked(upload: false)
        } catch ServerStorageError.notFound {
            if uploadLocalWhenMissing && (!database.Entries.isEmpty || !database.DeletedEntries.isEmpty) {
                SyncConflictResolver.normalize(&database)
                try ClipDatabaseFile.saveAtomic(databaseURL, database: database, password: password)
                let data = try Data(contentsOf: databaseURL)
                let metadata = try client.upload(data: data, expectedRevision: "")
                serverRevision = metadata.revision
                serverUploadPending = false
                markServerSuccessLocked(upload: true)
            } else {
                throw ServerStorageError.notFound
            }
        }
    }

    private func uploadToServerLocked() throws {
        guard let client = serverClient, client.isConfigured else { return }
        let data = try Data(contentsOf: databaseURL)
        do {
            let metadata = try client.upload(data: data, expectedRevision: serverRevision)
            serverRevision = metadata.revision
            serverUploadPending = false
            markServerSuccessLocked(upload: true)
        } catch ServerStorageError.conflict {
            try syncFromServerLocked(uploadLocalWhenMissing: false)
            let mergedData = try Data(contentsOf: databaseURL)
            let metadata = try client.upload(data: mergedData, expectedRevision: serverRevision)
            serverRevision = metadata.revision
            serverUploadPending = false
            markServerSuccessLocked(upload: true)
        } catch ServerStorageError.notFound {
            let metadata = try client.upload(data: data, expectedRevision: "")
            serverRevision = metadata.revision
            serverUploadPending = false
            markServerSuccessLocked(upload: true)
        } catch {
            markServerFailureLocked()
            throw error
        }
    }

    private func loadDownloadedDatabaseLocked(_ data: Data) throws -> ClipDatabase {
        let temp = databaseURL.deletingLastPathComponent()
            .appendingPathComponent(".clipman-server-download-\(UUID().uuidString).clipdb")
        try FileManager.default.createDirectory(at: temp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: temp, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: temp) }
        return try ClipDatabaseFile.load(temp, password: password)
    }

    private func hasLocalStateMissingFromServer(server: ClipDatabase, local: ClipDatabase) -> Bool {
        var normalizedServer = server
        var normalizedLocal = local
        SyncConflictResolver.normalize(&normalizedServer)
        SyncConflictResolver.normalize(&normalizedLocal)

        let serverDeleted = Set(normalizedServer.DeletedEntries.map(\.Id))
        if normalizedLocal.DeletedEntries.contains(where: { !serverDeleted.contains($0.Id) }) {
            return true
        }

        let serverIDs = Set(normalizedServer.Entries.map(\.Id))
        for entry in normalizedLocal.Entries where !entry.Text.isEmpty {
            if SyncConflictResolver.isDeleted(entry, in: normalizedServer) { continue }
            if !serverIDs.contains(entry.Id) && !normalizedServer.Entries.contains(where: { $0.Text == entry.Text }) {
                return true
            }
            if let serverEntry = normalizedServer.Entries.first(where: { $0.Id == entry.Id }),
               entry.ModifiedUnixMs > serverEntry.ModifiedUnixMs {
                return true
            }
        }
        return false
    }

    private func isDatabasePasswordError(_ error: Error) -> Bool {
        guard let databaseError = error as? ClipDatabaseError else { return false }
        switch databaseError {
        case .passwordRequired, .incorrectPassword:
            return true
        default:
            return false
        }
    }

    private func sortedEntriesLocked() -> [ClipEntry] {
        sortedEntriesLocked(sortMode: "LastUsed", descending: true)
    }

    private func sortedEntriesLocked(sortMode: String, descending: Bool) -> [ClipEntry] {
        let pinned = database.Entries.filter(\.Pinned).sorted {
            if $0.ManualOrder == $1.ManualOrder { return $0.CreatedUnixMs > $1.CreatedUnixMs }
            return $0.ManualOrder < $1.ManualOrder
        }
        let normal = sortNormalEntriesLocked(database.Entries.filter { !$0.Pinned }, sortMode: sortMode, descending: descending)
        return pinned + normal
    }

    private func sortNormalEntriesLocked(_ entries: [ClipEntry], sortMode: String, descending: Bool) -> [ClipEntry] {
        switch sortMode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "ADDED":
            return entries.sorted { descending ? $0.CreatedUnixMs > $1.CreatedUnixMs : $0.CreatedUnixMs < $1.CreatedUnixMs }
        case "TEXT":
            return entries.sorted {
                let result = $0.Text.localizedCaseInsensitiveCompare($1.Text)
                return descending ? result == .orderedDescending : result == .orderedAscending
            }
        case "GROUP":
            return entries.sorted {
                let result = $0.Group.localizedCaseInsensitiveCompare($1.Group)
                if result == .orderedSame { return $0.LastUsedUnixMs > $1.LastUsedUnixMs }
                return descending ? result == .orderedDescending : result == .orderedAscending
            }
        case "MACHINE":
            return entries.sorted {
                let result = $0.SourceMachine.localizedCaseInsensitiveCompare($1.SourceMachine)
                if result == .orderedSame { return $0.LastUsedUnixMs > $1.LastUsedUnixMs }
                return descending ? result == .orderedDescending : result == .orderedAscending
            }
        case "MANUAL":
            return entries.sorted {
                if $0.ManualOrder == $1.ManualOrder { return $0.LastUsedUnixMs > $1.LastUsedUnixMs }
                return descending ? $0.ManualOrder > $1.ManualOrder : $0.ManualOrder < $1.ManualOrder
            }
        case "LASTUSED":
            fallthrough
        default:
            return entries.sorted { descending ? $0.LastUsedUnixMs > $1.LastUsedUnixMs : $0.LastUsedUnixMs < $1.LastUsedUnixMs }
        }
    }

    private func normalizeManualOrderLocked() {
        SyncConflictResolver.normalize(&database)
    }

    private func nextManualOrderLocked() -> Int64 {
        (database.Entries.map(\.ManualOrder).max() ?? 0) + 1
    }

    private func pruneLocked(maxEntries: Int) {
        let pinned = database.Entries.filter(\.Pinned)
        let normal = database.Entries.filter { !$0.Pinned }.sorted { $0.LastUsedUnixMs > $1.LastUsedUnixMs }
        database.Entries = pinned + Array(normal.prefix(maxEntries))
    }

    private func resetWatcherLocked() {
        reloadWorkItem?.cancel()
        reloadWorkItem = nil
        source?.cancel()
        source = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }

        let directoryURL = databaseURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        fileDescriptor = open(directoryURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: [.write, .delete, .rename, .extend, .attrib], queue: queue)
        watcher.setEventHandler { [weak self] in
            self?.scheduleReloadLocked()
        }
        watcher.setCancelHandler { [fd = fileDescriptor] in
            if fd >= 0 { close(fd) }
        }
        source = watcher
        watcher.resume()
        fileDescriptor = -1
    }

    private func scheduleReloadLocked() {
        reloadWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let loaded = self.loadLocked()
            self.resetWatcherLocked()
            if loaded {
                DispatchQueue.main.async { self.delegate?.clipStoreDidChange() }
            }
        }
        reloadWorkItem = workItem
        queue.asyncAfter(deadline: .now() + .milliseconds(500), execute: workItem)
    }
}
