import XCTest
@testable import Clipman

final class HistoryRowPreviewTests: XCTestCase {
    func testLongEntryUsesBoundedPreviewWithoutChangingStoredText() {
        let fullText = String(repeating: "Long clipboard content ", count: 10_000)
        let entry = ClipEntry(Id: "long", Text: fullText)

        XCTAssertEqual(entry.Text, fullText)
        XCTAssertTrue(entry.historyPreview.wasTruncated)
        XCTAssertLessThanOrEqual(
            entry.displayText.unicodeScalars.count,
            HistoryRowPreview.maximumScalars + 3
        )
        XCTAssertTrue(entry.accessibilityLabelText.contains("Preview truncated"))
        XCTAssertFalse(entry.accessibilityLabelText.contains(fullText))
    }

    func testNameAndTextShareOneBoundedRowBudget() {
        let entry = ClipEntry(
            Id: "named",
            Text: String(repeating: "T", count: 50_000),
            Name: "Invoice date"
        )

        XCTAssertTrue(entry.displayText.hasPrefix("Invoice date: "))
        XCTAssertLessThanOrEqual(
            entry.displayText.unicodeScalars.count,
            HistoryRowPreview.maximumScalars + 3
        )
        XCTAssertTrue(entry.historyPreview.wasTruncated)
    }

    func testOrdinaryEntryIsNotMarkedAsTruncated() {
        let entry = ClipEntry(Id: "short", Text: "Short clipboard entry")

        XCTAssertEqual(entry.displayText, "Short clipboard entry")
        XCTAssertFalse(entry.historyPreview.wasTruncated)
        XCTAssertFalse(entry.accessibilityLabelText.contains("Preview truncated"))
    }

    func testOversizedTextIsNotReparsedForPerRowLinkActions() {
        let value = String(repeating: "x", count: HistoryRowPreview.maximumLinkInspectionScalars + 1)

        XCTAssertFalse(HistoryRowPreview.canInspectLinks(in: value))
        XCTAssertNil(LinkExtractor.exactHTTPURL(in: ClipEntry(Id: "long", Text: value)))
    }
}
