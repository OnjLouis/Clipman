import Foundation

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
        for incoming in source.Entries where !incoming.Text.isEmpty {
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
    }

    public static func normalize(_ database: inout ClipDatabase) {
        database.Version = max(1, database.Version)
        database.UpdatedUnixMs = TimeUtil.nowUnixMs()
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

    static func conflictSiblings(for canonicalURL: URL) -> [URL] {
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
        if incomingLastUsed > existing.LastUsedUnixMs {
            existing.LastUsedUnixMs = incomingLastUsed
        }
        if incoming.CreatedUnixMs > 0 && (existing.CreatedUnixMs == 0 || incoming.CreatedUnixMs < existing.CreatedUnixMs) {
            existing.CreatedUnixMs = incoming.CreatedUnixMs
        }
        if !incoming.Name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && incomingLastUsed >= existing.LastUsedUnixMs {
            existing.Name = incoming.Name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !incoming.Group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && incomingLastUsed >= existing.LastUsedUnixMs {
            existing.Group = incoming.Group.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !incoming.SourceMachine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && incomingLastUsed >= existing.LastUsedUnixMs {
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
