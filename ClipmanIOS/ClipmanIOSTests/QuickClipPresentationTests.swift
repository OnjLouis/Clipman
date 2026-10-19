import SwiftUI
import UIKit
import XCTest
@testable import Clipman

final class QuickClipPresentationTests: XCTestCase {
    @MainActor
    func testNativeButtonRoutesTouchAndVoiceOverToTheSameAction() {
        let button = QuickClipActivationButton(type: .system)
        var activations = 0
        button.activate = { activations += 1 }
        XCTAssertTrue(button.isAccessibilityElement)
        XCTAssertEqual(button.accessibilityLabel, "Quick Clip")
        XCTAssertTrue(button.accessibilityTraits.contains(.button))
        XCTAssertTrue(button.accessibilityActivate())
        XCTAssertEqual(activations, 1)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(activations, 2)
        button.isEnabled = false
        XCTAssertFalse(button.accessibilityActivate())
        XCTAssertEqual(activations, 2)
    }

    @MainActor
    func testVoiceOverActivationPresentsQuickClipAndFocusesItsText() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipmanQuickClipPresentation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = ClipmanAppModel(
            settings: .empty,
            quickClipDraftStore: ClipDraftStore(fileURL: root.appendingPathComponent("quick.json")),
            entryEditDraftStore: ClipDraftStore(fileURL: root.appendingPathComponent("edit.json")),
            readingStateStore: HistoryReadingStateStore(fileURL: root.appendingPathComponent("reading.json"))
        )
        app.isUnlocked = true
        let controller = UIHostingController(rootView: HistoryView().environmentObject(app))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            app.discardQuickClipDraft()
            window.isHidden = true
            window.rootViewController = nil
        }

        var button: NSObject?
        for _ in 0..<30 where button == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
            button = accessibleElement(named: "Quick Clip", in: controller.view)
        }
        let quickClip = try XCTUnwrap(button, "The toolbar must expose a named Quick Clip button")
        let section = app.selectedSection
        XCTAssertTrue(quickClip.accessibilityActivate(), "VoiceOver's default action must open the editor")
        for _ in 0..<30 where controller.presentedViewController == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(app.showingQuickClip)
        XCTAssertEqual(app.selectedSection, section, "Activation must not advance the history pager")
        let editor = try XCTUnwrap(controller.presentedViewController)
        var textView: UITextView?
        for _ in 0..<30 where textView?.isFirstResponder != true {
            try await Task.sleep(nanoseconds: 50_000_000)
            textView = descendants(of: editor.view).compactMap { $0 as? UITextView }.first
        }
        XCTAssertNotNil(textView)
        XCTAssertEqual(textView?.isFirstResponder, true)
        textView?.resignFirstResponder()
        app.searchText = "An unrelated history refresh"
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(textView?.isFirstResponder, false, "Refreshing history must not steal focus back")
    }

    @MainActor
    func testRepeatedQuickClipRequestsKeepTheUnsavedDraft() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipmanQuickClipReuse-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = ClipmanAppModel(
            settings: .empty,
            quickClipDraftStore: ClipDraftStore(fileURL: root.appendingPathComponent("quick.json")),
            entryEditDraftStore: ClipDraftStore(fileURL: root.appendingPathComponent("edit.json")),
            readingStateStore: HistoryReadingStateStore(fileURL: root.appendingPathComponent("reading.json"))
        )
        app.beginQuickClip()
        let draft = ClipEntry(Text: "Unfinished notes", Name: "Draft")
        app.updateQuickClipDraft(draft)
        app.beginQuickClip()
        XCTAssertTrue(app.showingQuickClip)
        XCTAssertEqual(app.quickClipDraft, draft)
        app.discardQuickClipDraft()
    }

    @MainActor
    private func descendants(of view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    @MainActor
    private func accessibleElement(named name: String, in root: NSObject) -> NSObject? {
        var pending = [root]
        var visited = Set<ObjectIdentifier>()
        while let object = pending.popLast(), visited.count < 500 {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            if object.accessibilityLabel == name { return object }
            if let view = object as? UIView { pending.append(contentsOf: view.subviews) }
            if let elements = object.accessibilityElements {
                pending.append(contentsOf: elements.compactMap { $0 as? NSObject })
            }
            let count = object.accessibilityElementCount()
            if count > 0 && count < 100 {
                for index in 0..<count {
                    if let element = object.accessibilityElement(at: index) as? NSObject {
                        pending.append(element)
                    }
                }
            }
        }
        return nil
    }
}
