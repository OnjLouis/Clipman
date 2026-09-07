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
}
