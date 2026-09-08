import XCTest
@testable import ClipmanCore

final class VisibleEntryOrderTests: XCTestCase {
    func testMovingPinnedLinkUsesAdjacentVisibleSlot() {
        let result = VisibleEntryOrder.moving(
            visibleIDs: ["first-link", "second-link"],
            selectedIDs: ["second-link"],
            direction: -1
        )

        XCTAssertEqual(result, ["second-link", "first-link"])
    }

    func testMovingAtVisibleBoundaryDoesNothing() {
        XCTAssertNil(VisibleEntryOrder.moving(
            visibleIDs: ["first-link", "second-link"],
            selectedIDs: ["first-link"],
            direction: -1
        ))
    }

    func testMovingMultipleVisibleEntriesKeepsTheirRelativeOrder() {
        XCTAssertEqual(VisibleEntryOrder.moving(
            visibleIDs: ["one", "two", "three", "four"],
            selectedIDs: ["two", "three"],
            direction: 1
        ), ["one", "four", "two", "three"])
    }
}
