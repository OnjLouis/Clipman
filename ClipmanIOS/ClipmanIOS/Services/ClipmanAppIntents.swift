import AppIntents

struct AddClipboardToClipmanIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Clipboard to Clipman"
    static let description = IntentDescription("Adds the current iOS clipboard text to Clipman history.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await ClipboardShortcutService.addClipboard()
        return .result(dialog: IntentDialog(stringLiteral: outcome.message))
    }
}

struct CopyLatestClipmanEntryIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Latest Clip"
    static let description = IntentDescription("Copies the newest Clipman history entry to the iOS clipboard.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await ClipboardShortcutService.copyLatest()
        return .result(dialog: IntentDialog(stringLiteral: outcome.message))
    }
}

struct ClipmanAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddClipboardToClipmanIntent(),
            phrases: [
                "Add clipboard to \(.applicationName)",
                "Save clipboard in \(.applicationName)",
                "Paste clipboard into \(.applicationName)"
            ],
            shortTitle: "Add Clipboard",
            systemImageName: "clipboard.badge.plus"
        )
        AppShortcut(
            intent: CopyLatestClipmanEntryIntent(),
            phrases: [
                "Copy latest from \(.applicationName)",
                "Get latest clip from \(.applicationName)"
            ],
            shortTitle: "Copy Latest Clip",
            systemImageName: "doc.on.clipboard"
        )
    }

    static var shortcutTileColor: ShortcutTileColor { .blue }
}
