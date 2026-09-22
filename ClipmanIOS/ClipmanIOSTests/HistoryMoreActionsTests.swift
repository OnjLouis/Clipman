import XCTest
@testable import Clipman

final class HistoryMoreActionsTests: XCTestCase {
    func testFirstPageOffersEveryOtherEnabledHistorySection() {
        let sections: [ClipmanAppModel.Section] = [.text, .richText, .links]

        XCTAssertEqual(
            HistoryMoreActionSections.available(from: sections, selected: .text),
            [.richText, .links]
        )
    }

    func testUnknownSelectionDoesNotHideAnyEnabledHistorySection() {
        let sections: [ClipmanAppModel.Section] = [.text, .links]

        XCTAssertEqual(
            HistoryMoreActionSections.available(from: sections, selected: .richText),
            sections
        )
    }
}
