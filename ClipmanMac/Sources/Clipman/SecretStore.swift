import Foundation
import ClipmanCore

@MainActor
final class SecretStore {
    private var database = SecretDatabase()
    private var passwordProvider: () -> String
    private(set) var databaseURL: URL

    init(databaseURL: URL, passwordProvider: @escaping () -> String) {
        self.databaseURL = databaseURL
        self.passwordProvider = passwordProvider
        load()
    }

    func setDatabaseURL(_ url: URL) {
        databaseURL = url
        load()
    }

    func entries() -> [SecretEntry] {
        database.Entries.sorted {
            $0.Name.localizedCaseInsensitiveCompare($1.Name) == .orderedAscending
        }
    }

    func entry(id: String) -> SecretEntry? {
        database.Entries.first { $0.Id == id }
    }

    func save(_ entry: SecretEntry) throws {
        guard !currentPassword().isEmpty else {
            throw ClipDatabaseError.passwordRequired
        }
        var updated = entry
        let now = TimeUtil.nowUnixMs()
        if let index = database.Entries.firstIndex(where: { $0.Id == entry.Id }) {
            updated.CreatedUnixMs = database.Entries[index].CreatedUnixMs
            updated.UpdatedUnixMs = now
            database.Entries[index] = updated
        } else {
            updated.CreatedUnixMs = now
            updated.UpdatedUnixMs = now
            database.Entries.append(updated)
        }
        database.UpdatedUnixMs = now
        try saveLocked()
    }

    func delete(id: String) throws {
        guard !currentPassword().isEmpty else {
            throw ClipDatabaseError.passwordRequired
        }
        database.Entries.removeAll { $0.Id == id }
        database.UpdatedUnixMs = TimeUtil.nowUnixMs()
        try saveLocked()
    }

    func changeDatabasePassword() throws {
        guard !currentPassword().isEmpty else { return }
        guard FileManager.default.fileExists(atPath: databaseURL.path) || !database.Entries.isEmpty else { return }
        database.UpdatedUnixMs = TimeUtil.nowUnixMs()
        try saveLocked()
    }

    func load() {
        do {
            database = try ClipDatabaseFile.loadCodable(databaseURL, password: currentPassword(), defaultValue: SecretDatabase())
        } catch {
            RuntimeLogger.write("Could not load secrets database: \(error.localizedDescription)")
            database = SecretDatabase()
        }
    }

    private func saveLocked() throws {
        try ClipDatabaseFile.saveAtomicCodable(databaseURL, value: database, password: currentPassword())
    }

    private func currentPassword() -> String {
        passwordProvider()
    }
}
