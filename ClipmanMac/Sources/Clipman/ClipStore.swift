import Foundation
import ClipmanCore

@MainActor
protocol ClipStoreDelegate: AnyObject {
    func clipStoreDidChange()
    func clipStoreNeedsPassword(for path: String) -> String?
    func clipStoreDidFail(error: Error)
}

final class ClipStore: @unchecked Sendable {
    weak var delegate: ClipStoreDelegate?

    private let queue = DispatchQueue(label: "Clipman.ClipStore")
    private var database = ClipDatabase()
    private var source: DispatchSourceFileSystemObject?
    private var reloadWorkItem: DispatchWorkItem?
    private var fileDescriptor: CInt = -1
    private var password = ""
    private(set) var databaseURL: URL
    private let machineName: String

    init(databaseURL: URL, machineName: String) {
        self.databaseURL = databaseURL
        self.machineName = machineName
    }

    func setDatabaseURL(_ url: URL, password: String = "") {
        queue.async {
            self.databaseURL = url
            self.password = password
            self.loadLocked()
            self.resetWatcherLocked()
            DispatchQueue.main.async { self.delegate?.clipStoreDidChange() }
        }
    }

    func load() {
        queue.async {
            self.loadLocked()
            self.resetWatcherLocked()
            DispatchQueue.main.async { self.delegate?.clipStoreDidChange() }
        }
    }

    func entries() -> [ClipEntry] {
        queue.sync { sortedEntriesLocked() }
    }

    func entries(sortMode: String, descending: Bool) -> [ClipEntry] {
        queue.sync { sortedEntriesLocked(sortMode: sortMode, descending: descending) }
    }

    func addText(_ text: String, maxEntries: Int = 1000) {
        guard !text.isEmpty else { return }
        queue.async {
            self.mergeLatestBeforeWriteLocked()
            let now = TimeUtil.nowUnixMs()
            if let index = self.database.Entries.firstIndex(where: { $0.Text == text }) {
                self.database.Entries[index].LastUsedUnixMs = now
                self.database.Entries[index].SourceMachine = self.machineName
            } else {
                self.database.Entries.append(ClipEntry(
                    Text: text,
                    SourceMachine: self.machineName,
                    CreatedUnixMs: now,
                    LastUsedUnixMs: now,
                    ManualOrder: self.nextManualOrderLocked()
                ))
            }
            self.pruneLocked(maxEntries: maxEntries)
            self.saveLocked()
            DispatchQueue.main.async { self.delegate?.clipStoreDidChange() }
        }
    }

    func markUsed(_ id: String) {
        queue.async {
            self.mergeLatestBeforeWriteLocked()
            guard let index = self.database.Entries.firstIndex(where: { $0.Id == id }) else { return }
            self.database.Entries[index].LastUsedUnixMs = TimeUtil.nowUnixMs()
            self.saveLocked()
        }
    }

    func togglePinned(_ id: String) {
        queue.async {
            self.mergeLatestBeforeWriteLocked()
            guard let index = self.database.Entries.firstIndex(where: { $0.Id == id }) else { return }
            self.database.Entries[index].Pinned.toggle()
            self.saveLocked()
            DispatchQueue.main.async { self.delegate?.clipStoreDidChange() }
        }
    }

    func delete(_ id: String) {
        queue.async {
            self.mergeLatestBeforeWriteLocked()
            guard let index = self.database.Entries.firstIndex(where: { $0.Id == id }),
                  !self.database.Entries[index].Pinned else {
                return
            }
            self.database.Entries.remove(at: index)
            self.saveLocked()
            DispatchQueue.main.async { self.delegate?.clipStoreDidChange() }
        }
    }

    func setNameAndText(id: String, name: String, text: String) {
        queue.async {
            self.mergeLatestBeforeWriteLocked()
            guard let index = self.database.Entries.firstIndex(where: { $0.Id == id }) else { return }
            self.database.Entries[index].Name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            self.database.Entries[index].Text = text
            self.database.Entries[index].LastUsedUnixMs = TimeUtil.nowUnixMs()
            self.saveLocked()
            DispatchQueue.main.async { self.delegate?.clipStoreDidChange() }
        }
    }

    func setGroup(ids: [String], group: String) {
        let idSet = Set(ids)
        let trimmed = group.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !idSet.isEmpty else { return }
        queue.async {
            self.mergeLatestBeforeWriteLocked()
            var changed = false
            for index in self.database.Entries.indices where idSet.contains(self.database.Entries[index].Id) {
                self.database.Entries[index].Group = trimmed
                self.database.Entries[index].LastUsedUnixMs = TimeUtil.nowUnixMs()
                changed = true
            }
            guard changed else { return }
            self.saveLocked()
            DispatchQueue.main.async { self.delegate?.clipStoreDidChange() }
        }
    }

    func insertTextsAfterSelected(_ entries: [ClipEntry], afterID: String?) {
        queue.async {
            let source = entries.filter { !$0.Text.isEmpty }
            guard !source.isEmpty else { return }
            self.mergeLatestBeforeWriteLocked()
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
                    Pinned: false,
                    ManualOrder: order + Int64(offset)
                ))
            }
            SyncConflictResolver.normalize(&self.database)
            self.saveLocked()
            DispatchQueue.main.async { self.delegate?.clipStoreDidChange() }
        }
    }

    func currentPassword() -> String {
        queue.sync { password }
    }

    private func loadLocked() {
        do {
            _ = try SyncConflictResolver.resolveDatabaseConflicts(databaseURL: databaseURL, password: password)
            database = try loadDatabaseWithPasswordLocked()
            normalizeManualOrderLocked()
        } catch {
            DispatchQueue.main.async { self.delegate?.clipStoreDidFail(error: error) }
        }
    }

    private func loadDatabaseWithPasswordLocked() throws -> ClipDatabase {
        do {
            return try ClipDatabaseFile.load(databaseURL, password: password)
        } catch ClipDatabaseError.passwordRequired {
            if let supplied = DispatchQueue.main.sync(execute: { delegate?.clipStoreNeedsPassword(for: databaseURL.path) }) {
                password = supplied
                return try ClipDatabaseFile.load(databaseURL, password: supplied)
            }
            throw ClipDatabaseError.passwordRequired
        }
    }

    private func mergeLatestBeforeWriteLocked() {
        do {
            _ = try SyncConflictResolver.resolveDatabaseConflicts(databaseURL: databaseURL, password: password)
            let latest = try loadDatabaseWithPasswordLocked()
            SyncConflictResolver.merge(into: &database, source: latest)
            SyncConflictResolver.normalize(&database)
        } catch {
            DispatchQueue.main.async { self.delegate?.clipStoreDidFail(error: error) }
        }
    }

    private func saveLocked() {
        do {
            database.UpdatedUnixMs = TimeUtil.nowUnixMs()
            try ClipDatabaseFile.saveAtomic(databaseURL, database: database, password: password)
            resetWatcherLocked()
        } catch {
            DispatchQueue.main.async { self.delegate?.clipStoreDidFail(error: error) }
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
            self.loadLocked()
            self.resetWatcherLocked()
            DispatchQueue.main.async { self.delegate?.clipStoreDidChange() }
        }
        reloadWorkItem = workItem
        queue.asyncAfter(deadline: .now() + .milliseconds(500), execute: workItem)
    }
}
