import CryptoKit
import Foundation

struct OptimisticEntryDeletion: Sendable {
    let previousDatabase: ClipDatabase
    let optimisticDatabase: ClipDatabase

    init?(database: ClipDatabase, entryID: String, machineName: String) {
        guard let entryIndex = database.Entries.firstIndex(where: { $0.Id == entryID }) else { return nil }
        previousDatabase = database
        var updated = database
        let entry = updated.Entries.remove(at: entryIndex)
        let now = TimeUtil.nowUnixMs()
        let marker = DeletedClipEntry(
            Id: entry.Id,
            TextHash: SyncConflictResolver.textHash(entry.Text),
            DeletedUnixMs: now,
            SourceMachine: machineName
        )
        if let markerIndex = updated.DeletedEntries.firstIndex(where: { $0.Id == entry.Id }) {
            updated.DeletedEntries[markerIndex] = marker
        } else {
            updated.DeletedEntries.append(marker)
        }
        updated.Version = max(1, updated.Version)
        updated.UpdatedUnixMs = now
        for index in updated.Entries.indices {
            updated.Entries[index].ManualOrder = Int64(index + 1)
        }
        optimisticDatabase = updated
    }

    func restoredDatabase(ifCurrentMatches current: ClipDatabase) -> ClipDatabase? {
        guard SyncConflictResolver.hasSameContent(current, optimisticDatabase) else { return nil }
        return previousDatabase
    }
}

enum SyncConflictResolver {
    static func hasSameContent(_ left: ClipDatabase, _ right: ClipDatabase) -> Bool {
        left.Entries == right.Entries && left.DeletedEntries == right.DeletedEntries
    }

    static func merge(target: ClipDatabase, source: ClipDatabase) -> ClipDatabase {
        var merged = target
        mergeDeletedEntries(into: &merged, source: source)
        applyDeletedEntries(&merged)
        let deletionIndex = DeletionIndex(merged.DeletedEntries)
        var entryIndexesByID: [String: Int] = [:]
        var entryIndexesByText: [String: Int] = [:]
        for index in merged.Entries.indices {
            let entry = merged.Entries[index]
            if !entry.Id.isEmpty, entryIndexesByID[entry.Id.lowercased()] == nil {
                entryIndexesByID[entry.Id.lowercased()] = index
            }
            if entryIndexesByText[entry.Text] == nil {
                entryIndexesByText[entry.Text] = index
            }
        }

        for incoming in source.Entries where !incoming.Text.isEmpty {
            if deletionIndex.contains(incoming) { continue }
            if !incoming.Id.isEmpty, let idIndex = entryIndexesByID[incoming.Id.lowercased()] {
                let previousText = merged.Entries[idIndex].Text
                mergeEntry(existing: &merged.Entries[idIndex], incoming: incoming)
                if previousText != merged.Entries[idIndex].Text {
                    entryIndexesByText.removeValue(forKey: previousText)
                }
                if entryIndexesByText[merged.Entries[idIndex].Text] == nil {
                    entryIndexesByText[merged.Entries[idIndex].Text] = idIndex
                }
                continue
            }
            if let textIndex = entryIndexesByText[incoming.Text] {
                mergeEntry(existing: &merged.Entries[textIndex], incoming: incoming)
                if !merged.Entries[textIndex].Id.isEmpty,
                   entryIndexesByID[merged.Entries[textIndex].Id.lowercased()] == nil {
                    entryIndexesByID[merged.Entries[textIndex].Id.lowercased()] = textIndex
                }
                entryIndexesByText[merged.Entries[textIndex].Text] = textIndex
                continue
            }
            merged.Entries.append(incoming)
            let index = merged.Entries.count - 1
            if !incoming.Id.isEmpty {
                entryIndexesByID[incoming.Id.lowercased()] = index
            }
            entryIndexesByText[incoming.Text] = index
        }
        applyDeletedEntries(&merged)
        normalize(&merged)
        return merged
    }

    static func addText(database: ClipDatabase, text: String, machineName: String, richText: RichTextPayload? = nil) -> ClipDatabase {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return database }
        var result = database
        let now = TimeUtil.nowUnixMs()
        let normalizedRichText = MobileRichTextClipboard.normalize(richText)
        if let index = result.Entries.firstIndex(where: { $0.Text == trimmed }) {
            result.Entries[index].LastUsedUnixMs = now
            result.Entries[index].SourceMachine = machineName
            if let normalizedRichText {
                result.Entries[index].RichText = normalizedRichText
                result.Entries[index].RichTextUpdatedUnixMs = now
            }
        } else {
            let nextOrder = (result.Entries.map(\.ManualOrder).max() ?? 0) + 1
            result.Entries.append(ClipEntry(
                Text: trimmed,
                SourceMachine: machineName,
                CreatedUnixMs: now,
                LastUsedUnixMs: now,
                ModifiedUnixMs: now,
                ManualOrder: nextOrder,
                RichText: normalizedRichText,
                RichTextUpdatedUnixMs: normalizedRichText == nil ? 0 : now
            ))
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
        updated.ModifiedUnixMs = updated.LastUsedUnixMs
        if updated.Text != result.Entries[index].Text {
            updated.RichText = nil
            updated.RichTextUpdatedUnixMs = updated.LastUsedUnixMs
        }
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
        result.Entries[index].ModifiedUnixMs = result.Entries[index].LastUsedUnixMs
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
        normalizeDeletedEntries(&target)
        var normalizedSource = source
        normalizeDeletedEntries(&normalizedSource)
        var byID = Dictionary(uniqueKeysWithValues: target.DeletedEntries.map { ($0.Id, $0) })
        for deleted in normalizedSource.DeletedEntries where !deleted.Id.isEmpty {
            if var existing = byID[deleted.Id] {
                if deleted.DeletedUnixMs > existing.DeletedUnixMs {
                    byID[deleted.Id] = deleted
                } else if existing.TextHash.isEmpty && !deleted.TextHash.isEmpty {
                    existing.TextHash = deleted.TextHash
                    byID[deleted.Id] = existing
                }
            } else {
                byID[deleted.Id] = deleted
            }
        }
        target.DeletedEntries = Array(byID.values)
        normalizeDeletedEntries(&target)
    }

    private static func applyDeletedEntries(_ database: inout ClipDatabase) {
        guard !database.DeletedEntries.isEmpty else { return }
        let deletionIndex = DeletionIndex(database.DeletedEntries)
        database.Entries.removeAll { deletionIndex.contains($0) }
    }

    private static func normalize(_ database: inout ClipDatabase) {
        database.Version = max(1, database.Version)
        database.UpdatedUnixMs = TimeUtil.nowUnixMs()
        normalizeDeletedEntries(&database)
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

    private static func normalizeDeletedEntries(_ database: inout ClipDatabase) {
        let cutoff = TimeUtil.nowUnixMs() - Int64(90 * 24 * 60 * 60 * 1_000)
        var byID: [String: DeletedClipEntry] = [:]
        for marker in database.DeletedEntries {
            let id = marker.Id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            guard marker.DeletedUnixMs == 0 || marker.DeletedUnixMs >= cutoff else { continue }
            var normalized = marker
            normalized.Id = id
            normalized.TextHash = normalized.TextHash.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.DeletedUnixMs == 0 {
                normalized.DeletedUnixMs = TimeUtil.nowUnixMs()
            }
            if let existing = byID[id], existing.DeletedUnixMs >= normalized.DeletedUnixMs {
                if existing.TextHash.isEmpty && !normalized.TextHash.isEmpty {
                    var repaired = existing
                    repaired.TextHash = normalized.TextHash
                    byID[id] = repaired
                }
                continue
            }
            byID[id] = normalized
        }
        database.DeletedEntries = byID.values.sorted {
            if $0.DeletedUnixMs == $1.DeletedUnixMs { return $0.Id < $1.Id }
            return $0.DeletedUnixMs > $1.DeletedUnixMs
        }
    }

    private struct DeletionIndex {
        private let deletedIDs: Set<String>
        private let latestDeletionByTextHash: [String: Int64]

        init(_ deletedEntries: [DeletedClipEntry]) {
            deletedIDs = Set(deletedEntries.lazy.map(\.Id).filter { !$0.isEmpty })
            var byHash: [String: Int64] = [:]
            for marker in deletedEntries where !marker.TextHash.isEmpty {
                byHash[marker.TextHash] = max(byHash[marker.TextHash] ?? Int64.min, marker.DeletedUnixMs)
            }
            latestDeletionByTextHash = byHash
        }

        func contains(_ entry: ClipEntry) -> Bool {
            if deletedIDs.contains(entry.Id) { return true }
            guard !entry.Text.isEmpty else { return false }
            let hash = SyncConflictResolver.textHash(entry.Text)
            guard let deletedUnixMs = latestDeletionByTextHash[hash] else { return false }
            let entryChangedUnixMs = max(entry.CreatedUnixMs, entry.LastUsedUnixMs)
            return deletedUnixMs <= 0 || entryChangedUnixMs <= deletedUnixMs
        }
    }

    private static func mergeEntry(existing: inout ClipEntry, incoming: ClipEntry) {
        let incomingWins = incoming.LastUsedUnixMs >= existing.LastUsedUnixMs
        let incomingCreatedWins = incoming.CreatedUnixMs > existing.CreatedUnixMs
        let incomingModifiedWins = incoming.ModifiedUnixMs > existing.ModifiedUnixMs
        let bothLegacy = incoming.ModifiedUnixMs <= 0 && existing.ModifiedUnixMs <= 0
        let legacyTextRepair = bothLegacy
            && !existing.Id.isEmpty
            && existing.Id.caseInsensitiveCompare(incoming.Id) == .orderedSame
            && existing.Text != incoming.Text
        if incoming.LastUsedUnixMs > existing.LastUsedUnixMs {
            existing.LastUsedUnixMs = incoming.LastUsedUnixMs
        }
        if incoming.CreatedUnixMs > 0 && (existing.CreatedUnixMs == 0 || incomingCreatedWins || (!incomingWins && incoming.CreatedUnixMs < existing.CreatedUnixMs)) {
            existing.CreatedUnixMs = incoming.CreatedUnixMs
        }
        if incomingModifiedWins {
            let textChanged = existing.Text != incoming.Text
            existing.Text = incoming.Text
            existing.Name = incoming.Name.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.Group = incoming.Group.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.Pinned = incoming.Pinned
            existing.IsTemplate = incoming.IsTemplate
            existing.ManualOrder = incoming.ManualOrder
            existing.ModifiedUnixMs = incoming.ModifiedUnixMs
            if textChanged {
                existing.RichText = incoming.RichText
                existing.RichTextUpdatedUnixMs = max(incoming.RichTextUpdatedUnixMs, incoming.ModifiedUnixMs)
            }
        } else if bothLegacy {
            if legacyTextRepair {
                existing.Text = incoming.Text
                existing.RichText = incoming.RichText
                existing.RichTextUpdatedUnixMs = max(existing.RichTextUpdatedUnixMs, incoming.RichTextUpdatedUnixMs)
            }
            if !incoming.Name.isEmpty && incomingWins {
                existing.Name = incoming.Name
            }
            if !incoming.Group.isEmpty && incomingWins {
                existing.Group = incoming.Group
            }
            existing.Pinned = existing.Pinned || incoming.Pinned
            existing.IsTemplate = existing.IsTemplate || incoming.IsTemplate
            if existing.ManualOrder <= 0 || (incoming.ManualOrder > 0 && incoming.ManualOrder < existing.ManualOrder) {
                existing.ManualOrder = incoming.ManualOrder
            }
        }
        if !incoming.SourceMachine.isEmpty && (incomingWins || incomingCreatedWins) {
            existing.SourceMachine = incoming.SourceMachine
        }
        if incoming.RichTextUpdatedUnixMs > existing.RichTextUpdatedUnixMs {
            existing.RichText = incoming.RichText
            existing.RichTextUpdatedUnixMs = incoming.RichTextUpdatedUnixMs
        }
    }
}
