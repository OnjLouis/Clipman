import XCTest
@testable import ClipmanCore

final class ClipMergeTests: XCTestCase {
    func testRequiresMatchingSecondEventFromSameApplication() {
        var detector = ClipMergeDetector()
        XCTAssertFalse(detector.observe(text("A", source: "Writer"), nowMilliseconds: 1000, enabled: true, windowMilliseconds: 500, deliberate: false).shouldMerge)
        detector.setCurrentHistoryID("a", matching: "A")
        XCTAssertFalse(detector.observe(text("B", source: "Writer"), nowMilliseconds: 5000, enabled: true, windowMilliseconds: 500, deliberate: false).shouldMerge)
        detector.setCurrentHistoryID("b", matching: "B")
        let decision = detector.observe(text("B", source: "Writer"), nowMilliseconds: 5450, enabled: true, windowMilliseconds: 500, deliberate: false)
        XCTAssertTrue(decision.shouldMerge)
        XCTAssertEqual(decision.base?.historyID, "a")
        XCTAssertEqual(decision.firstTap?.historyID, "b")
    }

    func testRejectsDifferentApplicationMixedTypesAndOperations() {
        var detector = ClipMergeDetector()
        _ = detector.observe(text("A", source: "Writer"), nowMilliseconds: 1000, enabled: true, windowMilliseconds: 500, deliberate: false)
        _ = detector.observe(text("B", source: "Writer"), nowMilliseconds: 2000, enabled: true, windowMilliseconds: 500, deliberate: false)
        XCTAssertFalse(detector.observe(text("B", source: "Browser"), nowMilliseconds: 2200, enabled: true, windowMilliseconds: 500, deliberate: false).shouldMerge)

        detector.reset()
        _ = detector.observe(files("base", operation: "Move"), nowMilliseconds: 1000, enabled: true, windowMilliseconds: 500, deliberate: false)
        _ = detector.observe(files("next", operation: "Copy"), nowMilliseconds: 2000, enabled: true, windowMilliseconds: 500, deliberate: false)
        XCTAssertFalse(detector.observe(files("next", operation: "Copy"), nowMilliseconds: 2200, enabled: true, windowMilliseconds: 500, deliberate: false).shouldMerge)
    }

    func testDefaultsAndSeparatorBounds() {
        XCTAssertEqual(ClipMergeDetector.normalizeWindow(1), 200)
        XCTAssertEqual(ClipMergeDetector.normalizeWindow(9999), 2000)
        XCTAssertEqual(ClipMergeDetector.separator(mode: "NewLine", custom: ""), "\n")
        XCTAssertEqual(ClipMergeDetector.separator(mode: "Custom", custom: "\\n--\\t"), "\n--\t")
    }

    func testLateSaveCompletionDoesNotOverwriteMergedState() {
        var detector = ClipMergeDetector()
        _ = detector.observe(text("A", source: "Writer"), nowMilliseconds: 1000, enabled: true, windowMilliseconds: 500, deliberate: false)
        detector.setCurrentHistoryID("a", matching: "A")
        _ = detector.observe(text("B", source: "Writer"), nowMilliseconds: 5000, enabled: true, windowMilliseconds: 500, deliberate: false)
        let decision = detector.observe(text("B", source: "Writer"), nowMilliseconds: 5200, enabled: true, windowMilliseconds: 500, deliberate: false)
        XCTAssertTrue(decision.shouldMerge)
        detector.completeMerge(text("A\nB", source: "Writer"), historyID: "merged")

        detector.setCurrentHistoryID("stale-b", matching: "B")
        _ = detector.observe(text("C", source: "Writer"), nowMilliseconds: 9000, enabled: true, windowMilliseconds: 500, deliberate: false)
        let next = detector.observe(text("C", source: "Writer"), nowMilliseconds: 9200, enabled: true, windowMilliseconds: 500, deliberate: false)
        XCTAssertEqual(next.base?.historyID, "merged")
    }

    private func text(_ value: String, source: String) -> ClipMergeObservation {
        ClipMergeObservation(kind: .text, signature: value, sourceApplication: source, values: [value])
    }

    private func files(_ value: String, operation: String) -> ClipMergeObservation {
        ClipMergeObservation(kind: .files, signature: value, sourceApplication: "Finder", operation: operation, values: [value])
    }
}
