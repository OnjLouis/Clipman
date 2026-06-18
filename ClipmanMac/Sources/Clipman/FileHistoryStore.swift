import Foundation
import ClipmanCore

@MainActor
protocol FileHistoryStoreDelegate: AnyObject {
    func fileHistoryStoreDidChange()
    func fileHistoryStoreDidFail(error: Error)
}

final class FileHistoryStore: @unchecked Sendable {
    weak var delegate: FileHistoryStoreDelegate?

    private let queue = DispatchQueue(label: "Clipman.FileHistoryStore")
    private var database = FileClipboardDatabase()
    private var password = ""
    private let databaseURL: URL
    private let machineName: String
    private let maxEvents = 200

    init(databaseURL: URL, machineName: String, password: String = "") {
        self.databaseURL = databaseURL
        self.machineName = machineName
        self.password = password
    }

    func setPassword(_ password: String) {
        queue.async {
            self.password = password
            self.loadLocked()
            DispatchQueue.main.async { self.delegate?.fileHistoryStoreDidChange() }
        }
    }

    func load() {
        queue.async {
            self.loadLocked()
            DispatchQueue.main.async { self.delegate?.fileHistoryStoreDidChange() }
        }
    }

    func events() -> [FileClipboardEvent] {
        queue.sync { sortedEventsLocked() }
    }

    func events(sortMode: String, descending: Bool) -> [FileClipboardEvent] {
        queue.sync { sortedEventsLocked(sortMode: sortMode, descending: descending) }
    }

    func add(files: [String], formats: [String], containsText: Bool) {
        let cleanFiles = files
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleanFiles.isEmpty else { return }

        queue.async {
            self.loadLocked()
            let now = TimeUtil.nowUnixMs()
            var event = FileClipboardEvent(
                CapturedUnixMs: now,
                Source: "",
                Operation: "Copy",
                SourceMachine: self.machineName,
                ContainsText: containsText,
                FileCount: cleanFiles.count,
                Files: cleanFiles,
                Formats: formats,
                ManualOrder: 1
            )

            if let existingIndex = self.database.Events.firstIndex(where: { self.sameFileEvent($0, event) }) {
                event.Pinned = self.database.Events[existingIndex].Pinned
                event.ManualOrder = self.database.Events[existingIndex].ManualOrder
                self.database.Events.remove(at: existingIndex)
            }
            if !event.Pinned {
                self.moveToTopOfBandLocked(&event)
            }
            self.database.Events.insert(event, at: 0)
            self.normalizeLocked()
            self.trimLocked()
            self.saveLocked()
            DispatchQueue.main.async { self.delegate?.fileHistoryStoreDidChange() }
        }
    }

    func togglePinned(_ id: String) {
        queue.async {
            self.loadLocked()
            guard let index = self.database.Events.firstIndex(where: { $0.Id == id }) else { return }
            self.database.Events[index].Pinned.toggle()
            if self.database.Events[index].ManualOrder <= 0 {
                self.database.Events[index].ManualOrder = self.nextManualOrderLocked()
            }
            self.saveLocked()
            DispatchQueue.main.async { self.delegate?.fileHistoryStoreDidChange() }
        }
    }

    func delete(_ id: String) {
        queue.async {
            self.loadLocked()
            guard let index = self.database.Events.firstIndex(where: { $0.Id == id }),
                  !self.database.Events[index].Pinned else {
                return
            }
            self.database.Events.remove(at: index)
            self.saveLocked()
            DispatchQueue.main.async { self.delegate?.fileHistoryStoreDidChange() }
        }
    }

    func clearNormal() {
        queue.async {
            self.loadLocked()
            self.database.Events.removeAll { !$0.Pinned }
            self.saveLocked()
            DispatchQueue.main.async { self.delegate?.fileHistoryStoreDidChange() }
        }
    }

    func removeUnavailable() {
        queue.async {
            self.loadLocked()
            self.database.Events.removeAll { event in
                !event.Pinned && (event.Files.isEmpty || event.Files.allSatisfy { path in
                    path.isEmpty || (!FileManager.default.fileExists(atPath: path))
                })
            }
            self.saveLocked()
            DispatchQueue.main.async { self.delegate?.fileHistoryStoreDidChange() }
        }
    }

    private func loadLocked() {
        do {
            database = try ClipDatabaseFile.loadCodable(databaseURL, password: password, defaultValue: FileClipboardDatabase())
            normalizeLocked()
        } catch ClipDatabaseError.passwordRequired, ClipDatabaseError.incorrectPassword {
            database = FileClipboardDatabase()
        } catch {
            DispatchQueue.main.async { self.delegate?.fileHistoryStoreDidFail(error: error) }
        }
    }

    private func saveLocked() {
        do {
            database.UpdatedUnixMs = TimeUtil.nowUnixMs()
            try ClipDatabaseFile.saveAtomicCodable(databaseURL, value: database, password: password)
        } catch {
            DispatchQueue.main.async { self.delegate?.fileHistoryStoreDidFail(error: error) }
        }
    }

    private func sortedEventsLocked() -> [FileClipboardEvent] {
        sortedEventsLocked(sortMode: "Manual", descending: false)
    }

    private func sortedEventsLocked(sortMode: String, descending: Bool) -> [FileClipboardEvent] {
        let pinned = database.Events.filter(\.Pinned).sorted {
            if $0.ManualOrder == $1.ManualOrder { return $0.CapturedUnixMs > $1.CapturedUnixMs }
            return $0.ManualOrder < $1.ManualOrder
        }
        let normal = sortNormalEventsLocked(database.Events.filter { !$0.Pinned }, sortMode: sortMode, descending: descending)
        return pinned + normal
    }

    private func sortNormalEventsLocked(_ events: [FileClipboardEvent], sortMode: String, descending: Bool) -> [FileClipboardEvent] {
        switch sortMode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "TIME":
            return events.sorted { descending ? $0.CapturedUnixMs > $1.CapturedUnixMs : $0.CapturedUnixMs < $1.CapturedUnixMs }
        case "FILES":
            return events.sorted {
                if $0.FileCount == $1.FileCount { return primaryName($0).localizedCaseInsensitiveCompare(primaryName($1)) == .orderedAscending }
                return descending ? $0.FileCount > $1.FileCount : $0.FileCount < $1.FileCount
            }
        case "NAME":
            return events.sorted {
                let result = primaryName($0).localizedCaseInsensitiveCompare(primaryName($1))
                if result == .orderedSame { return $0.CapturedUnixMs > $1.CapturedUnixMs }
                return descending ? result == .orderedDescending : result == .orderedAscending
            }
        case "OPERATION":
            return events.sorted {
                let result = $0.Operation.localizedCaseInsensitiveCompare($1.Operation)
                if result == .orderedSame { return primaryName($0).localizedCaseInsensitiveCompare(primaryName($1)) == .orderedAscending }
                return descending ? result == .orderedDescending : result == .orderedAscending
            }
        case "SOURCE":
            return events.sorted {
                let result = $0.Source.localizedCaseInsensitiveCompare($1.Source)
                if result == .orderedSame { return primaryName($0).localizedCaseInsensitiveCompare(primaryName($1)) == .orderedAscending }
                return descending ? result == .orderedDescending : result == .orderedAscending
            }
        case "MANUAL":
            fallthrough
        default:
            return events.sorted {
                if $0.ManualOrder == $1.ManualOrder { return $0.CapturedUnixMs > $1.CapturedUnixMs }
                return descending ? $0.ManualOrder > $1.ManualOrder : $0.ManualOrder < $1.ManualOrder
            }
        }
    }

    private func primaryName(_ event: FileClipboardEvent) -> String {
        guard let first = event.Files.first, !first.isEmpty else {
            return event.Operation.isEmpty ? "File event" : event.Operation
        }
        let name = URL(fileURLWithPath: first).lastPathComponent
        return name.isEmpty ? first : name
    }

    private func normalizeLocked() {
        for index in database.Events.indices {
            if database.Events[index].Id.isEmpty {
                database.Events[index].Id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            }
            if database.Events[index].CapturedUnixMs <= 0 {
                database.Events[index].CapturedUnixMs = TimeUtil.nowUnixMs()
            }
            if database.Events[index].SourceMachine.isEmpty {
                database.Events[index].SourceMachine = machineName
            }
            database.Events[index].Files = database.Events[index].Files.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            database.Events[index].FileCount = max(database.Events[index].FileCount, database.Events[index].Files.count)
        }
        var next: Int64 = 1
        for event in sortedEventsLocked() {
            guard let index = database.Events.firstIndex(where: { $0.Id == event.Id }) else { continue }
            if database.Events[index].ManualOrder <= 0 {
                database.Events[index].ManualOrder = next
            }
            next = max(next, database.Events[index].ManualOrder + 1)
        }
    }

    private func trimLocked() {
        guard database.Events.count > maxEvents else { return }
        let normal = database.Events
            .filter { !$0.Pinned }
            .sorted { $0.ManualOrder < $1.ManualOrder }
        let removable = database.Events.count - maxEvents
        let ids = Set(normal.suffix(removable).map(\.Id))
        database.Events.removeAll { ids.contains($0.Id) }
    }

    private func moveToTopOfBandLocked(_ event: inout FileClipboardEvent) {
        for index in database.Events.indices where database.Events[index].Pinned == event.Pinned && database.Events[index].ManualOrder > 0 {
            database.Events[index].ManualOrder += 1
        }
        event.ManualOrder = 1
    }

    private func nextManualOrderLocked() -> Int64 {
        (database.Events.map(\.ManualOrder).max() ?? 0) + 1
    }

    private func sameFileEvent(_ left: FileClipboardEvent, _ right: FileClipboardEvent) -> Bool {
        let leftFiles = left.Files.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.sorted()
        let rightFiles = right.Files.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.sorted()
        return !leftFiles.isEmpty && leftFiles == rightFiles
    }
}
