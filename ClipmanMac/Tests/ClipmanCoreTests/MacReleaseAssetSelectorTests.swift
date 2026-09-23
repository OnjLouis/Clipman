import XCTest
@testable import ClipmanCore

final class MacReleaseAssetSelectorTests: XCTestCase {
    func testAppleSiliconSelectsItsOwnAssetRegardlessOfListingOrder() {
        let assets = ["Clipman-macOS-Intel-3.1.5.zip", "Clipman-macOS-3.1.5.zip"]

        XCTAssertEqual(
            MacReleaseAssetSelector.preferredName(in: assets, version: "3.1.5", architecture: .appleSilicon),
            "Clipman-macOS-3.1.5.zip"
        )
    }

    func testIntelSelectsOnlyAnIntelAsset() {
        let assets = ["Clipman-macOS-3.1.5.zip", "Clipman-macOS-Intel-3.1.5.zip"]

        XCTAssertEqual(
            MacReleaseAssetSelector.preferredName(in: assets, version: "3.1.5", architecture: .intel),
            "Clipman-macOS-Intel-3.1.5.zip"
        )
        XCTAssertNil(MacReleaseAssetSelector.preferredName(
            in: ["Clipman-macOS-3.1.5.zip", "ClipmanMac-3.1.5.zip"],
            version: "3.1.5",
            architecture: .intel
        ))
    }

    func testIgnoresDifferentVersionsAndLookalikeNames() {
        XCTAssertNil(MacReleaseAssetSelector.preferredName(
            in: ["Clipman-macOS-Intel-3.1.4.zip", "Clipman-macOS-Intel-3.1.5-debug.zip"],
            version: "3.1.5",
            architecture: .intel
        ))
    }
}
