import Foundation
import ClipmanCore

@MainActor
protocol ClipStoreDelegate: AnyObject {
    func clipStoreDidChange()
    func clipStoreNeedsPassword(for path: String) -> String?
    func clipStoreDidFail(error: Error)
    func clipStoreServerSyncDidRecover()
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

    init(databaseURL: URL, machineName: String) {
        self.databaseURL = databaseURL
        self.machineName = machineName
    }

    func setMachineName(_ value: String) {
        queue.sync {
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                self.machineName = name
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
            self.resetServerStatusLocked()
            self.serverClient = enabled ? ServerStorageClient(
                serverURL: serverURL,
                token: serverToken,
                databasePassword: self.password,
                caCertPEM: serverCaCertPEM,
                caHost: serverCaHost
            ) : nil
            guard let client = self.serverClient, client.isConfigured else {
                self.serverClient = nil
                if self.serverFailureReported {
                    self.serverFailureReported = false
                    DispatchQueue.main.async { self.delegate?.clipStoreServerSyncDidRecover() }
                }
                return
            }

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
        guard !text.isEmpty else {
            Task { @MainActor in
                completion?(false)
            }
            return
        }
        let trimmedGroup = group.trimmingCharacters(in: .whitespacesAndNewlines)
        queue.async {
            guard self.mergeLatestBeforeWriteLocked() else {
                Task { @MainActor in
                    completion?(false)
                }
                return
            }
            let now = TimeUtil.nowUnixMs()
            let normalizedGroup = self.canonicalGroupLocked(trimmedGroup)
            if let index = self.database.Entries.firstIndex(where: { $0.Text == text }) {
                self.database.Entries[index].LastUsedUnixMs = now
                self.database.Entries[index].SourceMachine = self.machineName
                if let richText = RichTextData.normalize(richText) {
                    self.database.Entries[index].RichText = richText
                    self.database.Entries[index].RichTextUpdatedUnixMs = now
                }
                if !normalizedGroup.isEmpty {
                    self.database.Entries[index].Group = normalizedGroup
                    self.database.Entries[index].ModifiedUnixMs = now
                }
            } else {
                let normalizedRichText = RichTextData.normalize(richText)
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
                completion?(saved)
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

    func insertTextsAfterSelected(_ entries: [ClipEntry], afterID: String?) {
        queue.async {
            let source = entries.filter { !$0.Text.isEmpty }
            guard !source.isEmpty else { return }
            guard self.mergeLatestBeforeWriteLocked() else { return }
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
                    ManualOrder: order + Int64(offset)
                ))
            }
            SyncConflictResolver.normalize(&self.database)
            self.saveLocked()
            DispatchQueue.main.async { self.delegate?.clipStoreDidChange() }
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
            let revisionChanged = metadata.revision != serverRevision
            guard revisionChanged || serverUploadPending else {
                markServerSuccessLocked(upload: false)
                return
            }
            do {
                try syncFromServerLocked(uploadLocalWhenMissing: false)
                if revisionChanged {
                    DispatchQueue.main.async { self.delegate?.clipStoreDidChange() }
                }
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

    private func syncFromServerLocked(uploadLocalWhenMissing: Bool) throws {
        guard let client = serverClient, client.isConfigured else { return }
        if serverSyncInProgress { return }
        serverSyncInProgress = true
        defer { serverSyncInProgress = false }

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
