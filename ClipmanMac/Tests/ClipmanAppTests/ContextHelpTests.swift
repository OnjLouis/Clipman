import AppKit
import Carbon
import XCTest
import ClipmanCore
@testable import Clipman

final class ContextHelpTests: XCTestCase {
    @MainActor func testHotkeyActionsRunDuringAnOpenModalEditor() {
        _ = NSApplication.shared
        let modal = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        let finished = expectation(description: "Hotkey opened and closed its modal editor")
        var enabled = true
        var handledWhileModal = false
        let safety = Timer(timeInterval: 0.5, repeats: false) { _ in
            MainActor.assumeIsolated { if NSApp.modalWindow === modal { NSApp.abortModal() } }
        }
        RunLoop.main.add(safety, forMode: .common)
        RunLoop.main.add(safety, forMode: .modalPanel)
        defer { enabled = false; safety.invalidate(); modal.orderOut(nil) }
        HotkeyManager.scheduleAction {
            guard enabled else { return }
            HotkeyManager.scheduleAction {
                guard enabled else { return }
                handledWhileModal = NSApp.modalWindow === modal
                if handledWhileModal { NSApp.stopModal() }
            }
            NSApp.runModal(for: modal)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
        XCTAssertTrue(handledWhileModal, "Hotkeys queued behind the modal editor instead of running inside its event loop.")
    }
    @MainActor func testQuickClipReusesHiddenDraftWithoutNestingEditors() {
        _ = NSApplication.shared
        let controller = HistoryWindowController()
        var duplicated = false
        var restored = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let original = NSApp.modalWindow,
                  let text = KeyboardNavigation.orderedControls(in: original.contentView!).compactMap({ $0 as? NSTextView }).first else {
                XCTFail("Quick Clip did not expose its editor.")
                NSApp.abortModal()
                return
            }
            text.string = "Keep this unfinished draft"
            controller.hide()
            XCTAssertFalse(original.isVisible)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if controller.hasEntryEditor, let nested = NSApp.modalWindow, nested !== original {
                    duplicated = true
                    NSApp.abortModal()
                    nested.orderOut(nil)
                }
            }
            controller.showQuickClip()
            restored = NSApp.modalWindow === original && original.isVisible && text.string == "Keep this unfinished draft"
            let cancel = KeyboardNavigation.orderedControls(in: original.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }
            XCTAssertNotNil(cancel)
            cancel?.performClick(nil)
        }
        controller.showQuickClip()
        XCTAssertFalse(duplicated)
        XCTAssertTrue(restored)
        XCTAssertFalse(controller.hasEntryEditor)
        controller.window?.orderOut(nil)
    }
    @MainActor func testHistoryFocusRetriesDoNotStealFocusFromModalEditor() {
        _ = NSApplication.shared
        let controller = HistoryWindowController()
        let modal = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        controller.focusHistoryWindow(nil)
        let previousControl = NSButton(title: "Previous focus", target: nil, action: nil)
        controller.window!.contentView!.addSubview(previousControl)
        XCTAssertTrue(controller.window!.makeFirstResponder(previousControl))
        defer { modal.orderOut(nil); controller.window?.orderOut(nil) }
        modal.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            XCTAssertTrue(NSApp.modalWindow === modal)
            XCTAssertFalse(controller.window!.isKeyWindow, "A delayed History retry took focus from the editor.")
            XCTAssertTrue(controller.window!.firstResponder === previousControl, "A delayed History retry changed focus and announced the history list behind the editor.")
            NSApp.stopModal()
        }
        NSApp.runModal(for: modal)
    }
    @MainActor func testTabVisitsButtonsPopupsAndFieldsInBothDirections() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        let field = NSTextField(frame: NSRect(x: 10, y: 190, width: 200, height: 24))
        let check = NSButton(checkboxWithTitle: "Template entry", target: nil, action: nil)
        check.frame = NSRect(x: 10, y: 150, width: 200, height: 24)
        let popup = NSPopUpButton(frame: NSRect(x: 10, y: 110, width: 200, height: 24))
        popup.addItems(withTitles: ["One", "Two"])
        let hidden = NSButton(title: "Hidden", target: nil, action: nil)
        hidden.isHidden = true
        let disabled = NSButton(title: "Disabled", target: nil, action: nil)
        disabled.isEnabled = false
        let save = NSButton(title: "Save", target: nil, action: nil)
        save.frame = NSRect(x: 10, y: 10, width: 80, height: 24)
        for view in [field, check, popup, hidden, disabled, save] { window.contentView!.addSubview(view) }
        XCTAssertTrue(window.makeFirstResponder(field))
        for target in [check, popup, save, field] {
            XCTAssertTrue(KeyboardNavigation.move(in: window, backwards: false))
            XCTAssertTrue(KeyboardNavigation.focusedView(in: window) === target, "Forward: \(target)")
        }
        for target in [save, popup, check, field] {
            XCTAssertTrue(KeyboardNavigation.move(in: window, backwards: true))
            XCTAssertTrue(KeyboardNavigation.focusedView(in: window) === target, "Reverse: \(target)")
        }
    }
    @MainActor func testHistoryToolbarBelongsToKeyboardLoop() {
        _ = NSApplication.shared
        let controller = HistoryWindowController()
        let root = controller.window!.contentView!
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        let views = descendants(root)
        let search = views.first { $0 is NSSearchField }!
        var loop: [NSView] = []
        var next: NSView? = search
        while let view = next, !loop.contains(where: { $0 === view }), loop.count < 100 {
            loop.append(view)
            next = view.nextKeyView
        }
        for title in ["Set Group...", "Filter: All", "Sort: Last used", "Newest first", "Preferences..."] {
            let button = views.compactMap { $0 as? NSButton }.first { $0.title == title }!
            XCTAssertFalse(button.refusesFirstResponder, title)
            XCTAssertTrue(loop.contains { $0 === button }, title)
        }
        XCTAssertFalse(loop.contains { $0.accessibilityLabel() == "History status" })
        XCTAssertTrue(controller.window!.makeFirstResponder(search))
        let available = loop.filter { !$0.isHiddenOrHasHiddenAncestor && $0.acceptsFirstResponder && ($0 as? NSControl)?.isEnabled != false }
        for target in Array(available.dropFirst()) + [search] {
            XCTAssertTrue(KeyboardNavigation.move(in: controller.window!, backwards: false))
            XCTAssertTrue(KeyboardNavigation.focusedView(in: controller.window!) === target)
        }
        for target in Array(available.dropFirst().reversed()) + [search] {
            XCTAssertTrue(KeyboardNavigation.move(in: controller.window!, backwards: true))
            XCTAssertTrue(KeyboardNavigation.focusedView(in: controller.window!) === target)
        }
    }

    @MainActor func testEveryEnabledPreferencesControlHasBidirectionalTabAccess() {
        _ = NSApplication.shared
        let controller = PreferencesWindowController(settings: .defaults(applicationSupport: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clipman-keyboard-test")), historyIsEncrypted: false, rememberedPasswordExists: false, databasePasswordAvailable: false)
        let window = controller.window!
        window.contentView!.layoutSubtreeIfNeeded()
        let controls = KeyboardNavigation.orderedControls(in: window.contentView!).filter {
            $0.acceptsFirstResponder && ($0 as? NSControl)?.isEnabled != false
        }
        XCTAssertTrue(controls.contains { $0 is HotkeyCaptureField }, "Shortcut fields are intentionally read-only, but must still be reachable.")
        XCTAssertGreaterThan(controls.count, 30)
        XCTAssertTrue(window.makeFirstResponder(controls[0]))
        for target in Array(controls.dropFirst()) + [controls[0]] {
            XCTAssertTrue(KeyboardNavigation.move(in: window, backwards: false))
            XCTAssertTrue(KeyboardNavigation.focusedView(in: window) === target, "Forward: \(target.accessibilityLabel() ?? "control")")
        }
        for target in Array(controls.dropFirst().reversed()) + [controls[0]] {
            XCTAssertTrue(KeyboardNavigation.move(in: window, backwards: true))
            XCTAssertTrue(KeyboardNavigation.focusedView(in: window) === target, "Reverse: \(target.accessibilityLabel() ?? "control")")
        }
    }
    func testImageSourceNamesKeepRealFilenames() {
        XCTAssertEqual(RichTextData.sourceImageFilename("Clipboard image.png", application: "Safari"), "Clipboard image - Safari.png")
        XCTAssertEqual(RichTextData.sourceImageFilename("camera original.jpg", application: "Photos"), "camera original.jpg")
        XCTAssertEqual(RichTextData.sourceImageFilename("Clipboard image.png", application: ""), "Clipboard image.png")
        XCTAssertEqual(RichTextData.sourceImageFilename("Clipboard image.png", application: "../Bad:App\u{202e}"), "Clipboard image - ..BadApp.png")
    }

    func testViewerFilePreservesImageBytesAndCapturedDate() throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let captured: Int64 = 1700000000000
        let file = try EmbeddedImagePasteboardFile(data: png, filename: "viewer.png", capturedUnixMs: captured)
        XCTAssertEqual(try Data(contentsOf: file.fileURL), png)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.fileURL.path)
        XCTAssertEqual((attributes[.modificationDate] as? Date)?.timeIntervalSince1970, TimeInterval(captured) / 1000)
    }
    @MainActor func testExplanatoryHintsUseRetainedHelpAcrossAllControllers() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Clipman")
        for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let directHints = text.components(separatedBy: "\n").filter {
                $0.contains("setAccessibilityHelp(") && !$0.contains("setAccessibilityHelp(nil)")
            }
            XCTAssertEqual(directHints, [], "Automatic explanatory hints in \(file.lastPathComponent)")
        }
    }

    @MainActor func testDynamicHelpStaysQuietAndKeepsControlMetadata() {
        let button = NSButton(title: "Remove Channel", target: nil, action: nil)
        button.setAccessibilityLabel("Remove channel")
        button.isEnabled = false
        button.setContextHelp("Select a channel to remove.")
        XCTAssertTrue((button.accessibilityHelp() ?? "").isEmpty)
        XCTAssertEqual(button.contextHelpText, "Select a channel to remove.")
        button.isEnabled = true
        button.setContextHelp("Remove this channel without deleting its clips.")
        XCTAssertTrue((button.accessibilityHelp() ?? "").isEmpty)
        XCTAssertEqual(button.contextHelpText, "Remove this channel without deleting its clips.")
        XCTAssertEqual(button.accessibilityLabel(), "Remove channel")
        XCTAssertTrue(button.isEnabled)
    }

    @MainActor func testAdvancedDialogControlsHaveTailoredHelp() {
        for title in ["History status", "Selected entry group", "Clipman diagnostics report", "Current history password",
                      "Import file history password", "Export password choice", "New export password",
                      "Confirm new export password", "Continue", "Unlock"] {
            XCTAssertFalse(ContextHelp.description(title: title, hint: nil).hasPrefix("Use the focused control"), title)
        }
    }
    @MainActor func testPreferencesHaveTailoredHelp() {
        _ = NSApplication.shared
        let controller = PreferencesWindowController(settings: .defaults(applicationSupport: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clipman-help-test")), historyIsEncrypted: false, rememberedPasswordExists: false, databasePasswordAvailable: false)
        var missing: [String] = []
        func inspect(_ view: NSView) {
            if view is NSButton || view is NSPopUpButton || view is HotkeyCaptureField || view is NSTextView || (view as? NSTextField)?.isEditable == true {
                let title = view.accessibilityLabel() ?? (view as? NSButton)?.title ?? "Unnamed control"
                let text = ContextHelp.description(title: title, hint: view.contextHelpText)
                if text.hasPrefix("Use the focused control") { missing.append(title) }
                XCTAssertTrue((view.accessibilityHelp() ?? "").isEmpty, "Automatic explanatory hint: \(title)")
            }
            for child in view.subviews { inspect(child) }
        }
        inspect(controller.window!.contentView!)
        XCTAssertEqual(missing, [], "Missing help: \(missing)")
    }
    @MainActor func testHelpNeverReadsPrivateFieldValues() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        let field = NSSecureTextField(string: "private-value-not-help")
        field.setAccessibilityLabel("History password")
        field.setContextHelp("Unlock this device's encrypted history.")
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        defer { window.orderOut(nil) }
        let content = FocusedHelpContent.capture(in: window)
        XCTAssertEqual(content.title, "History password")
        XCTAssertEqual(content.instructions, "Unlock this device's encrypted history.")
        XCTAssertFalse(content.instructions.contains(field.stringValue))
        XCTAssertTrue((field.accessibilityHelp() ?? "").isEmpty)
    }

    @MainActor func testHelpKeyboardCycleAndClose() {
        _ = NSApplication.shared
        let panel = ContextHelp.makePanel(FocusedHelpContent(title: "History", instructions: "Select an entry.", restoreView: nil))
        defer { panel.orderOut(nil) }
        let editor = panel.initialFirstResponder as! HelpTextView
        XCTAssertFalse(editor.isEditable)
        XCTAssertTrue(editor.isSelectable)
        XCTAssertEqual(editor.string, "Select an entry.")
        XCTAssertEqual((editor.nextKeyView as? NSButton)?.title, "Open Manual")
        XCTAssertEqual((editor.nextKeyView?.nextKeyView as? NSButton)?.title, "Close")
        XCTAssertTrue(editor.nextKeyView?.nextKeyView?.nextKeyView === editor)
        var closed = 0
        panel.finish = { closed += 1 }
        panel.cancelOperation(nil)
        panel.performClose(nil)
        XCTAssertEqual(closed, 2)
    }

    @MainActor func testPlainF1PassesThroughHotkeyCapture() {
        _ = NSApplication.shared
        let field = HotkeyCaptureField()
        let original = HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_H), modifiers: [.command, .option])
        field.descriptor = original
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(kVK_F1))!
        XCTAssertFalse(field.performKeyEquivalent(with: event))
        field.keyDown(with: event)
        XCTAssertEqual(field.descriptor?.description, original.description)
    }
}
