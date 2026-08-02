import Photos
import XCTest
@testable import Clipman

final class EmbeddedImageActionTests: XCTestCase {
    private let coreActionLabels = ["View", "Edit", "Pin", "Delete"]

    func testImageActionsAppearOnceAfterCoreActionsInExpectedOrder() {
        let labels = EmbeddedImageHistoryActionPolicy.labels(
            appendingTo: coreActionLabels,
            for: sampleImage()
        )

        XCTAssertEqual(labels, ["View", "Edit", "Pin", "Delete", "Save to Photos", "Share"])
        XCTAssertEqual(labels.filter { $0 == "Save to Photos" }.count, 1)
        XCTAssertEqual(labels.filter { $0 == "Share" }.count, 1)
    }

    func testNonImageEntryHasNoImageActions() {
        XCTAssertEqual(
            EmbeddedImageHistoryActionPolicy.labels(appendingTo: coreActionLabels, for: nil),
            coreActionLabels
        )
    }

    func testPhotoAuthorizationDecisionsFailClosed() {
        XCTAssertEqual(EmbeddedImagePhotoAuthorizationDecision.decision(for: .authorized), .save)
        XCTAssertEqual(EmbeddedImagePhotoAuthorizationDecision.decision(for: .limited), .save)
        XCTAssertEqual(EmbeddedImagePhotoAuthorizationDecision.decision(for: .notDetermined), .request)
        XCTAssertEqual(EmbeddedImagePhotoAuthorizationDecision.decision(for: .denied), .deny)
        XCTAssertEqual(EmbeddedImagePhotoAuthorizationDecision.decision(for: .restricted), .deny)
    }

    func testShareFileKeepsExactBytesAndUsefulFilename() throws {
        let fileManager = FileManager.default
        let image = sampleImage()
        let file = try EmbeddedImageShareFile.create(for: image, fileManager: fileManager)
        defer { file.remove(fileManager: fileManager) }

        XCTAssertEqual(file.url.lastPathComponent, image.filename)
        XCTAssertEqual(try Data(contentsOf: file.url), image.data)
        XCTAssertTrue(file.url.path.hasPrefix(fileManager.temporaryDirectory.path))
        XCTAssertFalse(file.url.path.contains(image.altText))
    }

    private func sampleImage() -> EmbeddedImage {
        EmbeddedImage(
            filename: "Holiday photo.png",
            altText: "Image: Holiday photo.png",
            mimeType: "image/png",
            data: Data([0x89, 0x50, 0x4e, 0x47]),
            width: 1,
            height: 1,
            containsMetadata: true
        )
    }
}
