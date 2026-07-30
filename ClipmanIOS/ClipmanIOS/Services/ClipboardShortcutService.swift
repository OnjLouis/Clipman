import Foundation
import UIKit

struct ClipboardShortcutOutcome: Sendable {
    var succeeded: Bool
    var message: String
}

@MainActor
enum ClipboardShortcutService {
    private static let repository = MobileHistoryRepository.shared

    static func addClipboard() async -> ClipboardShortcutOutcome {
        let settings = SettingsStore.load()
        guard await authenticateIfNeeded(settings, reason: "Add the current clipboard to Clipman.") else {
            return ClipboardShortcutOutcome(succeeded: false, message: "Clipman was not unlocked.")
        }
        guard let payload = MobileRichTextClipboard.readCurrent() else {
            return failure("The clipboard does not contain text.", settings: settings)
        }

        do {
            let existing = try await currentDatabase(settings: settings)
            let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let alreadyExists = existing.Entries.contains { $0.Text == text }
            let updated = SyncConflictResolver.addText(
                database: existing,
                text: text,
                machineName: deviceName(settings),
                richText: settings.richTextEnabled ? payload.richText : nil
            )
            try await persist(updated, settings: settings)
            let message = alreadyExists
                ? "The clipboard text already exists in Clipman history."
                : "Clipboard text added to Clipman."
            postCompletion(message)
            return ClipboardShortcutOutcome(succeeded: true, message: message)
        } catch {
            return failure("Could not add the clipboard: \(error.localizedDescription)", settings: settings)
        }
    }

    static func copyLatest() async -> ClipboardShortcutOutcome {
        let settings = SettingsStore.load()
        guard await authenticateIfNeeded(settings, reason: "Copy the latest Clipman entry.") else {
            return ClipboardShortcutOutcome(succeeded: false, message: "Clipman was not unlocked.")
        }

        do {
            let database = try await currentDatabase(settings: settings)
            guard var latest = database.Entries
                .filter({ !$0.Text.isEmpty })
                .max(by: {
                    if $0.CreatedUnixMs == $1.CreatedUnixMs { return $0.Id < $1.Id }
                    return $0.CreatedUnixMs < $1.CreatedUnixMs
                }) else {
                return failure("Clipman history is empty.", settings: settings)
            }
            MobileRichTextClipboard.write(latest, includeRichText: settings.richTextEnabled)
            latest.LastUsedUnixMs = TimeUtil.nowUnixMs()
            latest.SourceMachine = deviceName(settings)
            let updated = SyncConflictResolver.updateEntry(
                database: database,
                entry: latest,
                machineName: deviceName(settings)
            )
            try await persist(updated, settings: settings)
            SoundService().play("copy", soundsEnabled: settings.soundsEnabled, hapticsEnabled: settings.hapticsEnabled)
            let message = "Copied the latest Clipman entry."
            postCompletion(message)
            return ClipboardShortcutOutcome(succeeded: true, message: message)
        } catch {
            return failure("Could not copy the latest entry: \(error.localizedDescription)", settings: settings)
        }
    }

    private static func currentDatabase(settings: ClipmanSettings) async throws -> ClipDatabase {
        try await repository.loadLocal(password: settings.historyPassword) ?? ClipDatabase()
    }

    private static func persist(_ database: ClipDatabase, settings: ClipmanSettings) async throws {
        _ = try await repository.saveLocal(
            database,
            password: settings.historyPassword,
            backupSettings: settings
        )
        guard settings.storageMode == .server,
              ServerStorageClient(settings: settings).isConfigured else { return }
        Task(priority: .utility) {
            _ = try? await repository.synchronize(
                settings: settings,
                current: database,
                localAlreadySaved: true
            )
        }
    }

    private static func authenticateIfNeeded(_ settings: ClipmanSettings, reason: String) async -> Bool {
        if !settings.requireAuthentication { return true }
        return await AuthenticationService.unlock(reason: reason)
    }

    private static func deviceName(_ settings: ClipmanSettings) -> String {
        let name = settings.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? UIDeviceMachine.name : name
    }

    private static func failure(_ message: String, settings: ClipmanSettings) -> ClipboardShortcutOutcome {
        SoundService().play("skip", soundsEnabled: settings.soundsEnabled, hapticsEnabled: settings.hapticsEnabled)
        postCompletion(message)
        return ClipboardShortcutOutcome(succeeded: false, message: message)
    }

    private static func postCompletion(_ message: String) {
        NotificationCenter.default.post(name: .clipmanShortcutCompleted, object: message)
    }
}

extension Notification.Name {
    static let clipmanShortcutCompleted = Notification.Name("ClipmanShortcutCompleted")
}
