import AppKit
import Carbon
import XCTest
import ClipmanCore
@testable import Clipman

final class ContextHelpTests: XCTestCase {
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
