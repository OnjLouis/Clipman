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
}
