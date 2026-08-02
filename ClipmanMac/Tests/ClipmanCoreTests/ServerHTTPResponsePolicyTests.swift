import XCTest
@testable import ClipmanCore

final class ServerHTTPResponsePolicyTests: XCTestCase {
    func testHeadResponseNeverRequiresAdvertisedContentLengthBytes() {
        XCTAssertFalse(ServerHTTPResponsePolicy.expectsBody(forMethod: "HEAD"))
        XCTAssertFalse(ServerHTTPResponsePolicy.expectsBody(forMethod: "head"))
    }

    func testDatabaseTransferMethodsExpectResponseBodies() {
        XCTAssertTrue(ServerHTTPResponsePolicy.expectsBody(forMethod: "GET"))
        XCTAssertTrue(ServerHTTPResponsePolicy.expectsBody(forMethod: "PUT"))
    }
}
