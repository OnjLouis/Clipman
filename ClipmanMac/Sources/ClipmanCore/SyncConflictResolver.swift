import Foundation
import CryptoKit

public enum SyncConflictResolver {
    public static func resolveDatabaseConflicts(databaseURL: URL, password: String) throws -> Bool {
        let conflicts = conflictSiblings(for: databaseURL)
        guard !conflicts.isEmpty else { return false }

        var merged = ClipDatabase()
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            merge(into: &merged, source: try ClipDatabaseFile.load(databaseURL, password: password))
        }
        for conflict in conflicts {
            merge(into: &merged, source: try ClipDatabaseFile.load(conflict, password: password))
        }

        normalize(&merged)
        try ClipDatabaseFile.saveAtomic(databaseURL, database: merged, password: password)
        for conflict in conflicts {
            try? FileManager.default.removeItem(at: conflict)
        }
        return true
    }

    public static func merge(into target: inout ClipDatabase, source: ClipDatabase) {
        _ = mergeDeletedEntries(into: &target, source: source)
        applyDeletedEntries(&target)
        for incoming in source.Entries where !incoming.Text.isEmpty {
            if isDeleted(incoming, in: target) { continue }
            if let idIndex = target.Entries.firstIndex(where: { !$0.Id.isEmpty && $0.Id.caseInsensitiveCompare(incoming.Id) == .orderedSame }) {
                mergeEntry(existing: &target.Entries[idIndex], incoming: incoming)
                continue
            }
            if let textIndex = target.Entries.firstIndex(where: { $0.Text == incoming.Text }) {
                mergeEntry(existing: &target.Entries[textIndex], incoming: incoming)
                continue
            }
            target.Entries.append(incoming)
        }
        applyDeletedEntries(&target)
    }

    public static func normalize(_ database: inout ClipDatabase) {
        database.Version = max(1, database.Version)
        database.UpdatedUnixMs = TimeUtil.nowUnixMs()
        normalizeDeletedEntries(&database)
        applyDeletedEntries(&database)
        let orderedIDs = database.Entries
            .sorted {
                let leftOrder = $0.ManualOrder <= 0 ? Int64.max : $0.ManualOrder
                let rightOrder = $1.ManualOrder <= 0 ? Int64.max : $1.ManualOrder
                if leftOrder == rightOrder { return $0.CreatedUnixMs < $1.CreatedUnixMs }
                return leftOrder < rightOrder
            }
            .map(\.Id)
        for (offset, id) in orderedIDs.enumerated() {
            guard let index = database.Entries.firstIndex(where: { $0.Id == id }) else { continue }
            if database.Entries[index].Id.isEmpty {
                database.Entries[index].Id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            }
            if database.Entries[index].CreatedUnixMs == 0 {
                database.Entries[index].CreatedUnixMs = TimeUtil.nowUnixMs()
            }
            if database.Entries[index].LastUsedUnixMs == 0 {
                database.Entries[index].LastUsedUnixMs = database.Entries[index].CreatedUnixMs
            }
            database.Entries[index].ManualOrder = Int64(offset + 1)
        }
    }

    public static func isDeleted(_ id: String, in database: ClipDatabase) -> Bool {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return database.DeletedEntries.contains { $0.Id == id }
    }

    public static func isDeleted(_ entry: ClipEntry, in database: ClipDatabase) -> Bool {
        isDeleted(entry, deletedEntries: database.DeletedEntries)
    }

    private static func isDeleted(_ entry: ClipEntry, deletedEntries: [DeletedClipEntry]) -> Bool {
        if deletedEntries.contains(where: { $0.Id == entry.Id }) { return true }
        guard !entry.Text.isEmpty else { return false }
        let hash = textHash(entry.Text)
        let entryChangedUnixMs = max(entry.CreatedUnixMs, entry.LastUsedUnixMs)
        return deletedEntries.contains {
            !$0.TextHash.isEmpty
                && $0.TextHash == hash
                && ($0.DeletedUnixMs <= 0 || entryChangedUnixMs <= $0.DeletedUnixMs)
        }
    }

    @discardableResult
    public static func mergeDeletedEntries(into target: inout ClipDatabase, source: ClipDatabase) -> Bool {
        normalizeDeletedEntries(&target)
        var normalizedSource = source
        normalizeDeletedEntries(&normalizedSource)
        guard !normalizedSource.DeletedEntries.isEmpty else { return false }

        var changed = false
        for deleted in normalizedSource.DeletedEntries where !deleted.Id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let index = target.DeletedEntries.firstIndex(where: { $0.Id == deleted.Id }) {
                if deleted.DeletedUnixMs > target.DeletedEntries[index].DeletedUnixMs {
                    target.DeletedEntries[index] = deleted
                    changed = true
                } else if target.DeletedEntries[index].TextHash.isEmpty && !deleted.TextHash.isEmpty {
                    target.DeletedEntries[index].TextHash = deleted.TextHash
                    changed = true
                }
            } else {
                target.DeletedEntries.append(deleted)
                changed = true
            }
        }
        normalizeDeletedEntries(&target)
        return changed
    }

    public static func addDeletedEntry(id: String, text: String, machineName: String, to database: inout ClipDatabase) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let marker = DeletedClipEntry(Id: trimmed, TextHash: textHash(text), DeletedUnixMs: TimeUtil.nowUnixMs(), SourceMachine: machineName)
        if let index = database.DeletedEntries.firstIndex(where: { $0.Id == trimmed }) {
            database.DeletedEntries[index] = marker
        } else {
            database.DeletedEntries.append(marker)
        }
        normalizeDeletedEntries(&database)
        applyDeletedEntries(&database)
    }

    public static func applyDeletedEntries(_ database: inout ClipDatabase) {
        guard !database.DeletedEntries.isEmpty else { return }
        let deletedEntries = database.DeletedEntries
        database.Entries.removeAll { isDeleted($0, deletedEntries: deletedEntries) }
    }

    private static func normalizeDeletedEntries(_ database: inout ClipDatabase) {
        let cutoff = TimeUtil.nowUnixMs() - Int64(90 * 24 * 60 * 60 * 1000)
        var byID: [String: DeletedClipEntry] = [:]
        for marker in database.DeletedEntries {
            let id = marker.Id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            guard marker.DeletedUnixMs == 0 || marker.DeletedUnixMs >= cutoff else { continue }
            var normalized = marker
            normalized.Id = id
            if normalized.TextHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                normalized.TextHash = ""
            }
            if normalized.DeletedUnixMs == 0 {
                normalized.DeletedUnixMs = TimeUtil.nowUnixMs()
            }
            if let existing = byID[id], existing.DeletedUnixMs >= normalized.DeletedUnixMs {
                continue
            }
            byID[id] = normalized
        }
        database.DeletedEntries = byID.values.sorted {
            if $0.DeletedUnixMs == $1.DeletedUnixMs { return $0.Id < $1.Id }
            return $0.DeletedUnixMs > $1.DeletedUnixMs
        }
    }

    public static func textHash(_ text: String) -> String {
        guard let data = text.data(using: .utf8), !data.isEmpty else { return "" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func conflictSiblings(for canonicalURL: URL) -> [URL] {
        let directory = canonicalURL.deletingLastPathComponent()
        let baseName = canonicalURL.deletingPathExtension().lastPathComponent
        let fileExtension = canonicalURL.pathExtension
        guard let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return children.filter { url in
            url != canonicalURL &&
                url.pathExtension.caseInsensitiveCompare(fileExtension) == .orderedSame &&
                isConflictName(url.deletingPathExtension().lastPathComponent, baseName: baseName)
        }
    }

    private static func mergeEntry(existing: inout ClipEntry, incoming: ClipEntry) {
        let incomingLastUsed = incoming.LastUsedUnixMs
        let incomingWins = incomingLastUsed >= existing.LastUsedUnixMs
        let incomingCreatedWins = incoming.CreatedUnixMs > existing.CreatedUnixMs
        if incomingLastUsed > existing.LastUsedUnixMs {
            existing.LastUsedUnixMs = incomingLastUsed
        }
        if incoming.CreatedUnixMs > 0
            && (existing.CreatedUnixMs == 0
                || incomingCreatedWins
                || (!incomingWins && incoming.CreatedUnixMs < existing.CreatedUnixMs)) {
            existing.CreatedUnixMs = incoming.CreatedUnixMs
        }
        if !incoming.Name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && incomingWins {
            existing.Name = incoming.Name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !incoming.Group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && incomingWins {
            existing.Group = incoming.Group.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !incoming.SourceMachine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (incomingWins || incomingCreatedWins) {
            existing.SourceMachine = incoming.SourceMachine.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        existing.Pinned = existing.Pinned || incoming.Pinned
        if existing.ManualOrder <= 0 || (incoming.ManualOrder > 0 && incoming.ManualOrder < existing.ManualOrder) {
            existing.ManualOrder = incoming.ManualOrder
        }
    }

    private static func isConflictName(_ name: String, baseName: String) -> Bool {
        guard name.range(of: baseName, options: [.caseInsensitive, .anchored]) != nil else { return false }
        let suffix = name.dropFirst(baseName.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suffix.isEmpty else { return false }
        let lower = suffix.lowercased()
        if lower.contains("conflicted copy") { return true }
        if lower.contains("[conflict]") { return true }
        if lower.contains(" conflict") { return true }
        if lower.hasPrefix("_conf(") { return true }
        if lower.hasPrefix(" _conf(") { return true }
        return looksLikeOneDriveComputerSuffix(String(suffix))
    }

    private static func looksLikeOneDriveComputerSuffix(_ suffix: String) -> Bool {
        var value = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 3 && value.count <= 80 else { return false }
        guard value.hasPrefix("-") || value.hasPrefix("(") || value.hasPrefix(" ") else { return false }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: " -()"))
        guard value.count >= 2 && value.count <= 64 else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}
