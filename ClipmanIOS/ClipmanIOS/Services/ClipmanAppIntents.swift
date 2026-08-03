import AppIntents

struct AddClipboardToClipmanIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Clipboard to Clipman"
    static let description = IntentDescription("Adds the current iOS clipboard text to Clipman history.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        ClipmanQuickActionCenter.shared.request(.addClipboard)
        return .result(dialog: "Opening Clipman to add the clipboard.")
    }
}

struct CopyLatestClipmanEntryIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Latest Clip"
    static let description = IntentDescription("Copies the newest Clipman history entry to the iOS clipboard.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        ClipmanQuickActionCenter.shared.request(.copyLatest)
        return .result(dialog: "Opening Clipman to copy the latest entry.")
    }
}

struct ClipmanAppShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
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
