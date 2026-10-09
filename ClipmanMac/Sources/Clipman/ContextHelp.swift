import AppKit
import ObjectiveC

struct FocusedHelpContent {
    let title: String
    let instructions: String
    let restoreView: NSView?

    @MainActor static func accessibilityFocus() -> NSObject? {
        NSApp.accessibilityFocusedUIElement as? NSObject
    }

    @MainActor static func capture(in window: NSWindow?) -> FocusedHelpContent {
        let responder = window?.firstResponder
        var view = responder as? NSView
        if let editor = view as? NSTextView, editor.isFieldEditor, let root = window?.contentView {
            func editingField(_ candidate: NSView) -> NSTextField? {
                if let field = candidate as? NSTextField, field.currentEditor() === responder { return field }
                for child in candidate.subviews { if let found = editingField(child) { return found } }
                return nil
            }
            view = editingField(root)
        }
        var focused = window === NSApp.keyWindow ? accessibilityFocus() : nil
        if view is NSTableView { focused = view }
        func metadata(_ object: NSObject?, _ selector: String) -> String? {
            guard let object, object.responds(to: NSSelectorFromString(selector)),
                  let value = object.perform(NSSelectorFromString(selector))?.takeUnretainedValue() as? String,
                  !value.isEmpty else { return nil }
            return value
        }
        // Descriptions only: field values can contain credentials or private text.
        let focusedTitle = metadata(focused, "accessibilityLabel")
        let focusedHint = (focused as? NSView)?.contextHelpText ?? metadata(focused, "accessibilityHelp")
        let hint = focusedTitle == nil ? focusedHint ?? view?.contextHelpText ?? view?.accessibilityHelp() : focusedHint
        let title = focusedTitle ?? view?.accessibilityLabel()
            ?? (view as? NSButton)?.title ?? "Current window"
        return FocusedHelpContent(title: title,
            instructions: ContextHelp.description(title: title, hint: hint),
            restoreView: view)
    }
}

final class HelpPanel: NSPanel {
    var finish: (() -> Void)?
    var manualButton: NSButton?
    var closeButton: NSButton?
    override func sendEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.type == .keyDown {
            if event.keyCode == 53 && modifiers.isEmpty || event.keyCode == 13 && modifiers == .command {
                finish?(); return
            }
            if event.keyCode == 48 && (modifiers.isEmpty || modifiers == .shift) {
                if modifiers == .shift { selectPreviousKeyView(nil) } else { selectNextKeyView(nil) }
                return
            }
        }
        super.sendEvent(event)
    }
    override func cancelOperation(_ sender: Any?) { finish?() }
    override func performClose(_ sender: Any?) { finish?() }
}

@MainActor final class ContextHelp: NSObject {
    static func description(title: String, hint: String?) -> String {
        if let hint, !hint.isEmpty { return hint }
        return instructions[title.lowercased()] ?? "Use the focused control to work with this window. Tab moves forward; Shift+Tab moves backward. Open Manual describes the complete workflow."
    }
    private static let instructions: [String: String] = [
        "history status": "Shows the entry count and storage connection state. Temporary action messages return to this useful summary automatically.",
        "selected entry group": "The group assigned to the selected entry. Set Group changes its group; the filter only changes what is visible.",
        "clipman diagnostics report": "Read-only diagnostic details for troubleshooting. You can select and copy the report; review it before sharing.",
        "current history password": "Unlock the live history before exporting it. This check does not change the password or its remembered state.",
        "import file history password": "Password used to encrypt the file being imported. This may differ from your current history password.",
        "export password choice": "Choose current encryption, a separate export password, or an unencrypted export. This affects only the exported file, not live history.",
        "new export password": "Encrypt this export with a separate password. Keep it safely; it is required to import the file elsewhere.",
        "confirm new export password": "Retype the export password to catch mistakes before writing the file.",
        "continue": "Accept the reviewed choice and continue. Validation may ask you to correct missing or inconsistent information.",
        "unlock": "Unlock the encrypted database with the entered password. This does not change the password.",
        "choose...": "Select the dedicated folder that will contain Clipman's settings and history. A shared cloud folder must be synchronized by its provider.",
        "monitoring enabled": "Automatically record new clipboard items while Clipman runs. Turning this off leaves saved history available; explicit capture commands remain separate.",
        "run clipman at login": "Start the menu-extra clipboard manager when you sign into this Mac. History stays hidden until you request it.",
        "confirm before deleting entries": "Ask before removing history entries. Removing a file-history event never deletes the original file.",
        "authority fingerprint": "Compare this public SHA-256 certificate fingerprint with a trusted copy from the server owner before accepting a private authority.",
        "entry group": "Organize this clip under a group. Names differing only by case are treated as the same group.",
        "pinned": "Protect this entry from normal history limits and bulk clearing. Unpin it to let those rules apply again.",
        "template entry": "Resolve supported template fields when this text is copied. Preview the result before relying on it; images cannot be templates.",
        "use this entry for quick paste": "Assign a global shortcut to this entry. The Quick Paste mode determines whether it copies, pastes, or restores the prior clipboard.",
        "preview template": "View the result after template fields are resolved without changing the saved template.",
        "template variables": "View the available template fields and what each expands to.",
        "paste and restore previous clipboard": "Paste this entry into the previous application, then restore the clipboard contents that were there before.",
        "paste and keep target on clipboard": "Paste this entry into the previous application and leave it on the clipboard.",
        "copy to clipboard only": "Copy this entry without sending a paste command to another application.",
        "secret name": "Visible label for this device-local secret. Its private value is not shown in the secrets list.",
        "secret value": "Private text kept in this device's encrypted secrets database, not shared clipboard history.",
        "confirm secret value": "Retype the private value to catch mistakes before saving. Help never reads the value.",
        "quick paste": "Paste the selected secret using its configured mode. Its value is not added to shared history.",
        "add": "Create a new device-local secret with a name, private value and optional global shortcut.",
        "properties": "Edit the selected secret's name, private value and shortcut.",
        "delete": "Remove the selected secret after confirmation. This does not remove shared history.",
        "add channel": "Create a sync channel. Routing rules are evaluated in order; the first matching channel receives an entry.",
        "edit channel": "Edit the selected channel's conditions. Saving may relocate matching entries.",
        "edit subscriptions": "Choose which channels the selected device receives. Unsubscribing hides entries locally without deleting them from shared history.",
        "save sync rules and close": "Apply routing and subscription changes, then close. Older clients without sync-rule support receive only main history.",
        "close without saving": "Close without applying the pending routing or subscription changes.",
        "clip details": "Read the selected clip's metadata. Arrow keys move between details; Tab moves to the clip content or Close.",
        "search history, command+f": "Filter the visible history by text. Clear the search to show all entries in the current section and group or device filter.",
        "history sections": "Choose a history section. Left and Right switch sections; Option+Left and Option+Right reorder the focused tab.",
        "set selected entries group, command+g": "Assign a group to the selected clips. Names differing only by case are treated as the same group.",
        "preferences, command+,": "Review this Mac's clipboard, storage, privacy and shortcut preferences. Save and Close applies pending changes.",
        "history storage type": "Local or shared folder uses your selected data folder. Clipman Server exchanges encrypted history with your server. File history and secrets remain device-local.",
        "server host": "Enter the reachable server address and port. Use HTTPS for a remote connection; a wildcard listen address is not a client destination.",
        "clipman server host": "Enter the reachable server address and port. Use HTTPS for a remote connection; a wildcard listen address is not a client destination.",
        "history password": "Unlock the encrypted history. Use the same password on devices that should share a server bucket. The server token alone does not select your history.",
        "confirm password": "Retype the new history password before saving. Leave both password fields blank to retain the current password.",
        "duplicate handling": "Move to top reuses an existing entry; Ignore leaves it in place; Keep both retains separate copies.",
        "clipmerge window, milliseconds": "Time allowed for a deliberate second copy that starts an append, from 200 to 2000 milliseconds. Shorter windows reduce accidental merging.",
        "clipmerge text separator": "Choose what separates appended clipboard selections. This is independent of copying several selected history entries.",
        "selected-clips join": "Choose what separates entries copied together from history. No separator joins them directly; this is independent of ClipMerge.",
        "multiple-entry separator": "Choose what separates entries copied together from history. No separator joins them directly; this is independent of ClipMerge.",
        "maximum entries": "Limit normal text history. Zero means no count limit. Pinned entries are retained.",
        "maximum entry age, days": "Limit the age of normal text history. Zero means no age limit. Pinned entries are retained.",
        "ignored applications": "One application name, bundle identifier or executable name per line. Automatic capture ignores these apps; deliberate imports remain separate.",
        "entry name": "Give this clip a descriptive name without changing its text or image content.",
        "name": "Give this clip a descriptive name without changing its text or image content.",
        "group": "Organize the entry under a group. Group names differing only by case are treated as the same group.",
        "clipboard text": "Edit the stored clip text. Return inserts a new line; Command+Enter or Command+S saves.",
        "quick paste mode": "Choose whether the global shortcut pastes and restores the previous clipboard, pastes and keeps this clip, or only copies it.",
        "save and close": "Save these preferences and close the window. Command+S also saves; closing without saving discards pending changes.",
        "save": "Save this entry. Command+Enter or Command+S also saves; Return inserts a new line in its text.",
        "cancel": "Close this dialog without accepting its pending changes.",
        "close": "Close this window and return to the previous control.",
        "generate password": "Generate a strong history password. Keep a safe copy and use it on the devices that should share history.",
        "use no password": "Remove history encryption after confirmation. Do not use this for a public or shared server.",
        "check for updates": "Look for a newer Mac client. This does not alter clipboard history.",
        "save list position": "Remember your place in each history section when closing and reopening history.",
        "sensitive data mode": "Exclude selected detected patterns from automatic capture only. Existing history, the system clipboard and deliberate imports are unchanged.",
        "check for updates automatically": "Choose when automatic update checks run. Manual Check for Updates remains available.",
        "text history": "Text clips in the current filter. Select with arrow keys. Return copies and closes; optional paste follows your preference. F2 edits; F4 views.",
        "links history": "Web links in the current filter. Return copies and closes; Command+Return includes the name. Option+Return opens the link and closes History.",
        "rich text history": "Formatted clips and embedded images. Copy retains supported formatting; Option+Return opens a selected image in its default app.",
        "file history": "Device-local file events, not uploaded files. Return restores the file selection to the clipboard. Option+Return reveals one selected file or folder and closes History. Clearing history never deletes the original files."
    ]

    static let shared = ContextHelp()
    private var monitor: Any?
    private var manual: (() -> Void)?
    private var panel: HelpPanel?
    private var owner: NSWindow?
    private weak var restoreView: NSView?

    func install(openManual: @escaping () -> Void) {
        manual = openManual
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard event.keyCode == 122, modifiers.isEmpty else { return event }
            self?.show(); return nil
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; manual = nil
    }
    func show() {
        guard panel == nil, let owner = NSApp.keyWindow else { return }
        let content = FocusedHelpContent.capture(in: owner)
        self.owner = owner; restoreView = content.restoreView
        let dialog = Self.makePanel(content)
        panel = dialog
        dialog.finish = { [weak self] in self?.finish() }
        dialog.manualButton?.target = self; dialog.manualButton?.action = #selector(openManual)
        dialog.closeButton?.target = self; dialog.closeButton?.action = #selector(closeHelp)
        dialog.center(); dialog.makeKeyAndOrderFront(nil)
        dialog.makeFirstResponder(dialog.initialFirstResponder)
        NSApp.runModal(for: dialog)
        dialog.orderOut(nil); panel = nil
        if owner.isVisible {
            owner.makeKeyAndOrderFront(nil)
            if let restoreView, restoreView.window === owner { owner.makeFirstResponder(restoreView) }
        }
        self.owner = nil; restoreView = nil
    }
    @objc private func openManual() { manual?() }
    @objc private func closeHelp() { finish() }
    private func finish() { NSApp.stopModal() }

    static func makePanel(_ content: FocusedHelpContent) -> HelpPanel {
        let panel = HelpPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 300),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Help: " + content.title
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        let editor = HelpTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 220))
        editor.isEditable = false; editor.isSelectable = true; editor.isRichText = false
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.string = content.instructions
        editor.setAccessibilityLabel(content.title + " help")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = editor
        let manual = NSButton(title: "Open Manual", target: nil, action: nil)
        manual.setContextHelp("Open the complete manual.")
        let close = NSButton(title: "Close", target: nil, action: nil)
        panel.manualButton = manual; panel.closeButton = close
        close.setContextHelp("Close help and return to the previous control.")
        let buttons = NSStackView(views: [manual, close]); buttons.spacing = 12
        let stack = NSStackView(views: [scroll, buttons]); stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        let root = panel.contentView!
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])
        editor.nextKeyView = manual; manual.nextKeyView = close; close.nextKeyView = editor
        editor.tabAction = { [weak panel] in panel?.makeFirstResponder(manual) }
        editor.backTabAction = { [weak panel] in panel?.makeFirstResponder(close) }
        panel.initialFirstResponder = editor
        return panel
    }
}


@MainActor private var contextHelpAssociation: UInt8 = 0

extension NSView {
    func setContextHelp(_ text: String?) {
        objc_setAssociatedObject(self, &contextHelpAssociation, text, .OBJC_ASSOCIATION_COPY_NONATOMIC)
        setAccessibilityHelp(nil)
    }
    var contextHelpText: String? {
        if let text = objc_getAssociatedObject(self, &contextHelpAssociation) as? String { return text }
        return superview?.contextHelpText
    }
}

final class HelpTextView: NSTextView {
    var tabAction: (() -> Void)?
    var backTabAction: (() -> Void)?
    override func insertTab(_ sender: Any?) { tabAction?() }
    override func insertBacktab(_ sender: Any?) { backTabAction?() }
}
