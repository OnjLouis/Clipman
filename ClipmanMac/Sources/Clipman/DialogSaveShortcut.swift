import AppKit
import Carbon

enum DialogSaveShortcut {
    private static let primaryModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    static func matches(_ event: NSEvent, acceptsCommandReturn: Bool) -> Bool {
        let modifiers = event.modifierFlags.intersection(primaryModifiers)
        guard modifiers == .command else { return false }
        if event.charactersIgnoringModifiers?.lowercased() == "s" {
            return true
        }
        guard acceptsCommandReturn else { return false }
        return event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter)
    }

    @MainActor
    static func runModal(_ alert: NSAlert, acceptsCommandReturn: Bool) -> NSApplication.ModalResponse {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard matches(event, acceptsCommandReturn: acceptsCommandReturn),
                  let saveButton = alert.buttons.first,
                  saveButton.isEnabled else {
                return event
            }
            saveButton.performClick(nil)
            return nil
        }
        defer {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        return alert.runModal()
    }
}

class SaveShortcutWindow: NSWindow {
    var saveShortcutHandler: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if DialogSaveShortcut.matches(event, acceptsCommandReturn: false),
           let saveShortcutHandler {
            saveShortcutHandler()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
