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

    func testCoalescesDuplicatesAndRejectsStaleCutSources() throws {
        var detector = ClipMergeDetector()
        _ = detector.observe(text("A", source: "Writer"), nowMilliseconds: 1000, enabled: true, windowMilliseconds: 500, deliberate: false)
        detector.setCurrentHistoryID("a", matching: "A")
        _ = detector.observe(text("B", source: "Writer", changeIdentifier: 20), nowMilliseconds: 2000, enabled: true, windowMilliseconds: 500, deliberate: false)
        detector.setCurrentHistoryID("b", matching: "B")
        let duplicate = detector.observe(text("B", source: "Writer", changeIdentifier: 20), nowMilliseconds: 2040, enabled: true, windowMilliseconds: 500, deliberate: false)
        XCTAssertTrue(duplicate.suppressDuplicate)
        XCTAssertFalse(duplicate.shouldMerge)
        XCTAssertTrue(detector.observe(text("B", source: "Writer", changeIdentifier: 21), nowMilliseconds: 2050, enabled: true, windowMilliseconds: 500, deliberate: false).shouldMerge)

        detector.reset()
        _ = detector.observe(text("A", source: "Thunderbird"), nowMilliseconds: 1000, enabled: true, windowMilliseconds: 1000, deliberate: false)
        detector.setCurrentHistoryID("a", matching: "A")
        _ = detector.observe(text("B", source: "Thunderbird", changeIdentifier: 30), nowMilliseconds: 2000, enabled: true, windowMilliseconds: 1000, deliberate: false)
        detector.setCurrentHistoryID("b", matching: "B")
        XCTAssertTrue(detector.observe(text("B", source: "Thunderbird", changeIdentifier: 31), nowMilliseconds: 2250, enabled: true, windowMilliseconds: 1000, deliberate: false).suppressDuplicate)
        XCTAssertTrue(detector.observe(text("B", source: "Thunderbird", changeIdentifier: 32), nowMilliseconds: 2800, enabled: true, windowMilliseconds: 1000, deliberate: false).shouldMerge)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClipmanCutMerge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldURL = directory.appendingPathComponent("old.txt")
        let newURL = directory.appendingPathComponent("new.txt")
        try Data("old".utf8).write(to: oldURL)
        try Data("new".utf8).write(to: newURL)

        detector.reset()
        _ = detector.observe(files(oldURL.path, operation: "Move", changeIdentifier: 40), nowMilliseconds: 3000, enabled: true, windowMilliseconds: 500, deliberate: false)
        let duplicateCut = detector.observe(files(oldURL.path, operation: "Move", changeIdentifier: 40), nowMilliseconds: 3100, enabled: true, windowMilliseconds: 500, deliberate: false)
        XCTAssertTrue(duplicateCut.suppressDuplicate)
        XCTAssertFalse(duplicateCut.shouldMerge)
        _ = detector.observe(files(newURL.path, operation: "Move", changeIdentifier: 50), nowMilliseconds: 4000, enabled: true, windowMilliseconds: 500, deliberate: false)
        let liveCutMerge = detector.observe(files(newURL.path, operation: "Move", changeIdentifier: 51), nowMilliseconds: 4010, enabled: true, windowMilliseconds: 500, deliberate: false)
        XCTAssertTrue(liveCutMerge.shouldMerge)
        XCTAssertTrue(ClipMergeFilePolicy.sourcesAreAvailable([oldURL.path, newURL.path]))
        try FileManager.default.removeItem(at: oldURL)
        XCTAssertFalse(ClipMergeFilePolicy.sourcesAreAvailable([oldURL.path, newURL.path]))
        detector.retainFirstTap(try XCTUnwrap(liveCutMerge.firstTap))
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

    private func text(_ value: String, source: String, changeIdentifier: Int = 0) -> ClipMergeObservation {
        ClipMergeObservation(kind: .text, signature: value, sourceApplication: source, changeIdentifier: changeIdentifier, values: [value])
    }

    private func files(_ value: String, operation: String, changeIdentifier: Int = 0) -> ClipMergeObservation {
        ClipMergeObservation(kind: .files, signature: value, sourceApplication: "Finder", operation: operation, changeIdentifier: changeIdentifier, values: [value])
    }
}
