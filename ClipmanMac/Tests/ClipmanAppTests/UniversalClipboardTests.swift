import AppKit
import XCTest
import ClipmanCore
@testable import Clipman

final class UniversalClipboardTests: XCTestCase {
    func testExistingSettingsKeepCaptureEnabledAndOptOutRoundTrips() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        for (json, expected) in [("{}", true), ("{\"captureUniversalClipboard\":false}", false)] {
            let settings = try decoder.decode(ClipmanSettings.self, from: Data(json.utf8))
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(settings)) as? [String: Any])
            XCTAssertEqual(saved["captureUniversalClipboard"] as? Bool, expected)
        }
    }

    @MainActor func testPreferencesExposesAnEnabledCheckboxByDefault() throws {
        _ = NSApplication.shared
        let settings = try JSONDecoder().decode(ClipmanSettings.self, from: Data("{}".utf8))
        let controller = PreferencesWindowController(settings: settings, historyIsEncrypted: false, rememberedPasswordExists: false, databasePasswordAvailable: false)
        let window = try XCTUnwrap(controller.window)
        defer { window.orderOut(nil) }
        let controls = KeyboardNavigation.orderedControls(in: try XCTUnwrap(window.contentView))
        let checkbox = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first {
            $0.accessibilityLabel() == "Save Universal Clipboard items to history"
        })
        XCTAssertEqual(checkbox.accessibilityRole(), .checkBox)
        XCTAssertEqual(checkbox.state, .on)
        XCTAssertTrue(window.makeFirstResponder(checkbox))
        checkbox.performClick(nil)
        XCTAssertEqual(checkbox.state, .off)
        let delegate = PreferencesSaveSpy()
        controller.preferencesDelegate = delegate
        _ = controller.perform(NSSelectorFromString("saveClicked"))
        XCTAssertEqual(delegate.saved?.captureUniversalClipboard, false)
    }

    @MainActor func testOptOutSkipsAutomaticCaptureButStillAllowsManualSave() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("Universal Clipboard test", forType: .string)
        item.setData(Data([1]), forType: NSPasteboard.PasteboardType("com.apple.is-remote-clipboard"))
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let monitor = ClipboardMonitor()
        let delegate = ClipboardCaptureSpy()
        monitor.delegate = delegate
        monitor.captureUniversalClipboard = false

        monitor.captureCurrentContents(from: pasteboard)
        XCTAssertTrue(delegate.texts.isEmpty)
        XCTAssertTrue(monitor.diagnosticsReport().contains("Skipped Universal Clipboard item"))
        XCTAssertEqual(delegate.skipSounds, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "Universal Clipboard test")

        monitor.saveCurrentContents(from: pasteboard)
        XCTAssertEqual(delegate.texts, ["Universal Clipboard test"])
        monitor.captureUniversalClipboard = true
        monitor.captureCurrentContents(from: pasteboard)
        XCTAssertEqual(delegate.texts, ["Universal Clipboard test", "Universal Clipboard test"])
    }

    @MainActor func testOptOutLeavesLocalCopiesAndConcealedDataRulesUnchanged() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor()
        let delegate = ClipboardCaptureSpy()
        monitor.delegate = delegate
        monitor.captureUniversalClipboard = false
        let local = NSPasteboardItem()
        local.setString("Local copy", forType: .string)
        local.setData(Data([1]), forType: NSPasteboard.PasteboardType("com.apple.is-remote-clipboard-unrelated"))
        XCTAssertTrue(pasteboard.writeObjects([local]))
        monitor.captureCurrentContents(from: pasteboard)
        XCTAssertEqual(delegate.texts, ["Local copy"])

        let concealed = NSPasteboardItem()
        concealed.setString("Concealed fixture", forType: .string)
        concealed.setData(Data([1]), forType: NSPasteboard.PasteboardType("com.apple.is-remote-clipboard"))
        concealed.setData(Data([1]), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([concealed]))
        monitor.saveCurrentContents(from: pasteboard)
        XCTAssertEqual(delegate.texts, ["Local copy"])
    }
}

@MainActor private final class PreferencesSaveSpy: PreferencesWindowControllerDelegate {
    var saved: ClipmanSettings?
    func preferencesWindow(_ controller: PreferencesWindowController, didUpdate settings: ClipmanSettings, passwordToSave: String?) -> Bool {
        saved = settings
        return true
    }
    func preferencesWindowShowSyncRules(_ controller: PreferencesWindowController) {}
}

@MainActor private final class ClipboardCaptureSpy: ClipboardMonitorDelegate {
    var texts: [String] = []
    var skipSounds = 0

    func clipboardMonitor(_ monitor: ClipboardMonitor, didCapture text: String, richText: RichTextPayload?, sourceApplication: String, observedAtMilliseconds: Int64, changeIdentifier: Int, deliberate: Bool, startupCapture: Bool) {
        texts.append(text)
    }
    func clipboardMonitor(_ monitor: ClipboardMonitor, didCaptureFiles files: [String], formats: [String], containsText: Bool, sourceApplication: String, operation: String, observedAtMilliseconds: Int64, changeIdentifier: Int, deliberate: Bool, startupCapture: Bool) { XCTFail("Unexpected file capture") }
    func clipboardMonitor(_ monitor: ClipboardMonitor, didCaptureAdditionalImage text: String, richText: RichTextPayload, sourceApplication: String, startupCapture: Bool) { XCTFail("Unexpected image capture") }
    func clipboardMonitor(_ monitor: ClipboardMonitor, didRejectImage reason: String, deliberate: Bool) { XCTFail("Unexpected image rejection") }
    func clipboardMonitorDidSkipIgnoredApplication(_ monitor: ClipboardMonitor) { skipSounds += 1 }
    func clipboardMonitorDidWriteInternalClipboard(_ monitor: ClipboardMonitor) { XCTFail("Capture rewrote the pasteboard") }
}
