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

    func entryCount() -> Int {
        queue.sync { database.Entries.count }
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

    func entry(id: String) -> ClipEntry? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return queue.sync {
            database.Entries.first { $0.Id == trimmed }
        }
    }

    func addText(_ text: String, group: String = "", maxEntries: Int = 1000) {
        guard !text.isEmpty else { return }
        let trimmedGroup = group.trimmingCharacters(in: .whitespacesAndNewlines)
        queue.async {
            guard self.mergeLatestBeforeWriteLocked() else { return }
            let now = TimeUtil.nowUnixMs()
            if let index = self.database.Entries.firstIndex(where: { $0.Text == text }) {
                self.database.Entries[index].LastUsedUnixMs = now
                self.database.Entries[index].SourceMachine = self.machineName
                if !trimmedGroup.isEmpty {
                    self.database.Entries[index].Group = trimmedGroup
                }
            } else {
                self.database.Entries.append(ClipEntry(
                    Text: text,
                    Group: trimmedGroup,
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
            self.database.Entries.remove(at: index)
            self.saveLocked()
            DispatchQueue.main.async { self.delegate?.clipStoreDidChange() }
        }
    }

    func setNameAndText(id: String, name: String, text: String) {
        queue.async {
            guard self.mergeLatestBeforeWriteLocked() else { return }
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
            guard self.mergeLatestBeforeWriteLocked() else { return }
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

            for (offset, entry) in ordered.enumerated() {
                guard let index = self.database.Entries.firstIndex(where: { $0.Id == entry.Id }) else { continue }
                self.database.Entries[index].ManualOrder = Int64(offset + 1)
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
                    Pinned: false,
                    ManualOrder: order + Int64(offset)
                ))
            }
            SyncConflictResolver.normalize(&self.database)
            self.saveLocked()
            DispatchQueue.main.async { self.delegate?.clipStoreDidChange() }
        }
    }

    func importEntries(from url: URL, completion: @escaping @Sendable (Result<Int, Error>) -> Void) {
        queue.async {
            do {
                guard self.mergeLatestBeforeWriteLocked() else {
                    DispatchQueue.main.async { completion(.failure(ClipDatabaseError.passwordRequired)) }
                    return
                }
                let imported = try self.loadImportedEntriesLocked(from: url)
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

    func exportDatabase(to url: URL, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
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
                    try ClipDatabaseFile.saveAtomic(url, database: snapshot, password: self.exportPassword(for: url))
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

    private func loadImportedEntriesLocked(from url: URL) throws -> [ClipEntry] {
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

        let imported = try ClipDatabaseFile.load(url, password: exportPassword(for: url))
        return imported.Entries.filter { !$0.Text.isEmpty }
    }

    private func exportPassword(for url: URL) -> String {
        url.pathExtension.caseInsensitiveCompare("clipdb") == .orderedSame ? password : ""
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

    private func mergeLatestBeforeWriteLocked() -> Bool {
        do {
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
