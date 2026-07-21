import CryptoKit
import Foundation

enum SyncConflictResolver {
    static func hasSameContent(_ left: ClipDatabase, _ right: ClipDatabase) -> Bool {
        left.Entries == right.Entries && left.DeletedEntries == right.DeletedEntries
    }

    static func merge(target: ClipDatabase, source: ClipDatabase) -> ClipDatabase {
        var merged = target
        mergeDeletedEntries(into: &merged, source: source)
        applyDeletedEntries(&merged)

        for incoming in source.Entries where !incoming.Text.isEmpty {
            if isDeleted(incoming, in: merged) { continue }
            if let idIndex = merged.Entries.firstIndex(where: { !$0.Id.isEmpty && $0.Id.caseInsensitiveCompare(incoming.Id) == .orderedSame }) {
                mergeEntry(existing: &merged.Entries[idIndex], incoming: incoming)
                continue
            }
            if let textIndex = merged.Entries.firstIndex(where: { $0.Text == incoming.Text }) {
                mergeEntry(existing: &merged.Entries[textIndex], incoming: incoming)
                continue
            }
            merged.Entries.append(incoming)
        }
        applyDeletedEntries(&merged)
        normalize(&merged)
        return merged
    }

    static func addText(database: ClipDatabase, text: String, machineName: String) -> ClipDatabase {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return database }
        var result = database
        let now = TimeUtil.nowUnixMs()
        if let index = result.Entries.firstIndex(where: { $0.Text == trimmed }) {
            result.Entries[index].LastUsedUnixMs = now
            result.Entries[index].SourceMachine = machineName
        } else {
            let nextOrder = (result.Entries.map(\.ManualOrder).max() ?? 0) + 1
            result.Entries.append(ClipEntry(Text: trimmed, SourceMachine: machineName, CreatedUnixMs: now, LastUsedUnixMs: now, ManualOrder: nextOrder))
        }
        normalize(&result)
        return result
    }

    static func updateEntry(database: ClipDatabase, entry: ClipEntry, machineName: String) -> ClipDatabase {
        var result = database
        guard let index = result.Entries.firstIndex(where: { $0.Id == entry.Id }) else { return result }
        var updated = entry
        updated.Text = updated.Text.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.Name = updated.Name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.Group = updated.Group.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.SourceMachine = machineName
        updated.LastUsedUnixMs = TimeUtil.nowUnixMs()
        if updated.Text.isEmpty {
            return deleteEntry(database: database, entryID: entry.Id, machineName: machineName)
        }
        result.Entries[index] = updated
        normalize(&result)
        return result
    }

    static func togglePinned(database: ClipDatabase, entryID: String) -> ClipDatabase {
        var result = database
        guard let index = result.Entries.firstIndex(where: { $0.Id == entryID }) else { return result }
        result.Entries[index].Pinned.toggle()
        result.Entries[index].LastUsedUnixMs = TimeUtil.nowUnixMs()
        normalize(&result)
        return result
    }

    static func deleteEntry(database: ClipDatabase, entryID: String, machineName: String) -> ClipDatabase {
        var result = database
        guard let entry = result.Entries.first(where: { $0.Id == entryID }) else { return result }
        let marker = DeletedClipEntry(Id: entry.Id, TextHash: textHash(entry.Text), DeletedUnixMs: TimeUtil.nowUnixMs(), SourceMachine: machineName)
        result.Entries.removeAll { $0.Id == entryID }
        if let index = result.DeletedEntries.firstIndex(where: { $0.Id == marker.Id }) {
            result.DeletedEntries[index] = marker
        } else {
            result.DeletedEntries.append(marker)
        }
        normalize(&result)
        return result
    }

    static func textHash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func mergeDeletedEntries(into target: inout ClipDatabase, source: ClipDatabase) {
        for deleted in source.DeletedEntries where !deleted.Id.isEmpty {
            if let index = target.DeletedEntries.firstIndex(where: { $0.Id == deleted.Id }) {
                if deleted.DeletedUnixMs > target.DeletedEntries[index].DeletedUnixMs {
                    target.DeletedEntries[index] = deleted
                }
            } else {
                target.DeletedEntries.append(deleted)
            }
        }
    }

    private static func isDeleted(_ entry: ClipEntry, in database: ClipDatabase) -> Bool {
        database.DeletedEntries.contains { $0.Id == entry.Id || (!$0.TextHash.isEmpty && $0.TextHash == textHash(entry.Text)) }
    }

    private static func applyDeletedEntries(_ database: inout ClipDatabase) {
        let ids = Set(database.DeletedEntries.map(\.Id).filter { !$0.isEmpty })
        let hashes = Set(database.DeletedEntries.map(\.TextHash).filter { !$0.isEmpty })
        database.Entries.removeAll { ids.contains($0.Id) || hashes.contains(textHash($0.Text)) }
    }

    private static func normalize(_ database: inout ClipDatabase) {
        database.Version = max(1, database.Version)
        database.UpdatedUnixMs = TimeUtil.nowUnixMs()
        applyDeletedEntries(&database)
        database.Entries = database.Entries
            .filter { !$0.Text.isEmpty }
            .sorted {
                let leftOrder = $0.ManualOrder <= 0 ? Int64.max : $0.ManualOrder
                let rightOrder = $1.ManualOrder <= 0 ? Int64.max : $1.ManualOrder
                if leftOrder == rightOrder { return $0.CreatedUnixMs < $1.CreatedUnixMs }
                return leftOrder < rightOrder
            }
        for index in database.Entries.indices {
            if database.Entries[index].Id.isEmpty {
                database.Entries[index].Id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            }
            database.Entries[index].ManualOrder = Int64(index + 1)
        }
    }

    private static func mergeEntry(existing: inout ClipEntry, incoming: ClipEntry) {
        let incomingWins = incoming.LastUsedUnixMs >= existing.LastUsedUnixMs
        let incomingCreatedWins = incoming.CreatedUnixMs > existing.CreatedUnixMs
        if incoming.LastUsedUnixMs > existing.LastUsedUnixMs {
            existing.LastUsedUnixMs = incoming.LastUsedUnixMs
        }
        if incoming.CreatedUnixMs > 0 && (existing.CreatedUnixMs == 0 || incomingCreatedWins || (!incomingWins && incoming.CreatedUnixMs < existing.CreatedUnixMs)) {
            existing.CreatedUnixMs = incoming.CreatedUnixMs
        }
        if !incoming.Name.isEmpty && incomingWins {
            existing.Name = incoming.Name
        }
        if !incoming.Group.isEmpty && incomingWins {
            existing.Group = incoming.Group
        }
        if !incoming.SourceMachine.isEmpty && (incomingWins || incomingCreatedWins) {
            existing.SourceMachine = incoming.SourceMachine
        }
        existing.Pinned = existing.Pinned || incoming.Pinned
        existing.IsTemplate = existing.IsTemplate || incoming.IsTemplate
        if existing.ManualOrder <= 0 || (incoming.ManualOrder > 0 && incoming.ManualOrder < existing.ManualOrder) {
            existing.ManualOrder = incoming.ManualOrder
        }
    }
}
