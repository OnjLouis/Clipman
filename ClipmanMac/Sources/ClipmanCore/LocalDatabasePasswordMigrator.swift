import Foundation

public enum LocalDatabasePasswordMigrator {
    public static func migrate(
        textHistoryURL: URL,
        fileHistoryURL: URL,
        secretsURL: URL,
        from oldPassword: String,
        to newPassword: String
    ) throws {
        guard oldPassword != newPassword else { return }

        let fileManager = FileManager.default
        let textDatabase: ClipDatabase? = fileManager.fileExists(atPath: textHistoryURL.path)
            ? try ClipDatabaseFile.load(textHistoryURL, password: oldPassword)
            : nil
        let fileDatabase: FileClipboardDatabase? = fileManager.fileExists(atPath: fileHistoryURL.path)
            ? try ClipDatabaseFile.loadCodable(fileHistoryURL, password: oldPassword, defaultValue: FileClipboardDatabase())
            : nil
        let secretsDatabase: SecretDatabase? = fileManager.fileExists(atPath: secretsURL.path)
            ? try ClipDatabaseFile.loadCodable(secretsURL, password: oldPassword, defaultValue: SecretDatabase())
            : nil

        var textChanged = false
        var filesChanged = false
        do {
            if let textDatabase {
                try ClipDatabaseFile.saveAtomic(textHistoryURL, database: textDatabase, password: newPassword)
                textChanged = true
            }
            if let fileDatabase {
                try ClipDatabaseFile.saveAtomicCodable(fileHistoryURL, value: fileDatabase, password: newPassword)
                filesChanged = true
            }
            if let secretsDatabase {
                try ClipDatabaseFile.saveAtomicCodable(secretsURL, value: secretsDatabase, password: newPassword)
            }
            try migrateSyncSiblings(beside: textHistoryURL, from: oldPassword, to: newPassword)
        } catch {
            if textChanged, let textDatabase {
                try? ClipDatabaseFile.saveAtomic(textHistoryURL, database: textDatabase, password: oldPassword)
            }
            if filesChanged, let fileDatabase {
                try? ClipDatabaseFile.saveAtomicCodable(fileHistoryURL, value: fileDatabase, password: oldPassword)
            }
            throw error
        }
    }

    /// Sync channel files, the sync-rules document and the pending
    /// write-through store live beside the history database and use the same
    /// container and password (`sync-rules-spec.md` section 2), so a password
    /// change has to carry them across as well. They are re-encrypted as raw
    /// payloads, which works uniformly for the channel databases and for the
    /// rules document, whose payload is not a `ClipDatabase`.
    private static func migrateSyncSiblings(beside textHistoryURL: URL, from oldPassword: String, to newPassword: String) throws {
        let folder = textHistoryURL.deletingLastPathComponent()
        guard let children = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return
        }
        let candidates = children
            .filter { url in
                guard url.pathExtension.lowercased() == "clipdb" else { return false }
                let name = url.lastPathComponent.lowercased()
                return name.hasPrefix("clipman-channel-")
                    || name == SyncRuleEngine.syncRulesFileName
                    || name == SyncRuleEngine.pendingChannelWritesFileName
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var migrated: [(url: URL, payload: Data)] = []
        do {
            for url in candidates {
                guard let payload = try ClipDatabaseFile.loadRawPayload(url, password: oldPassword) else { continue }
                try ClipDatabaseFile.saveRawPayloadAtomic(url, payload: payload, password: newPassword)
                migrated.append((url, payload))
            }
        } catch {
            for entry in migrated {
                try? ClipDatabaseFile.saveRawPayloadAtomic(entry.url, payload: entry.payload, password: oldPassword)
            }
            throw error
        }
    }
}
