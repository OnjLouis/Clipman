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
}
