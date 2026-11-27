import Foundation
import XCTest
@testable import ClipmanCore

final class LinkPresentationTests: XCTestCase {
    func testWebURLAcceptsOnlyStandaloneHTTPLinks() {
        XCTAssertEqual(LinkPresentation.webURL("https://example.com/article")?.host, "example.com")
        XCTAssertEqual(LinkPresentation.webURL("https://example.com/article  link")?.host, "example.com")
        XCTAssertNil(LinkPresentation.webURL("Read https://example.com/article"))
        XCTAssertNil(LinkPresentation.webURL("clipman://example.com/setup"))
    }

    func testDownloadLinkProvidesPersistentFallbackName() throws {
        XCTAssertEqual(
            LinkPresentation.make(urlText: "https://3.onj.me/bbcip/Inside%20No.%209.7z")?.label,
            "Inside No. 9.7z"
        )
    }

    func testEntryPreviewResolvesOnlyOneVisibleWebLinkAtSelection() {
        let first = "https://example.com/a(b)"
        let second = "http://example.org/q?part=2"
        let post = "Read (\(first)).\r\nThen \(second) or clipman://example.net."
        let text = post as NSString
        XCTAssertEqual(LinkPresentation.webURL(in: post, at: NSRange(location: NSMaxRange(text.range(of: first)), length: 0))?.absoluteString, first)
        let insideSecond = NSRange(location: text.range(of: second).location + 2, length: 5)
        XCTAssertEqual(LinkPresentation.webURL(in: post, at: insideSecond)?.absoluteString, second)
        XCTAssertNil(LinkPresentation.webURL(in: post, at: NSRange(location: 0, length: text.length)))
        XCTAssertNil(LinkPresentation.webURL(in: post, at: text.range(of: "Read")))
        XCTAssertNil(LinkPresentation.webURL(in: post, at: text.range(of: "clipman:")))
        XCTAssertEqual(LinkPresentation.previewURLs(in: post).map(\.absoluteString), [first, second])
    }
}
