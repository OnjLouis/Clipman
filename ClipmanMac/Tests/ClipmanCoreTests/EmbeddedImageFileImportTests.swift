import Foundation
import XCTest
@testable import ClipmanCore

final class EmbeddedImageFileImportTests: XCTestCase {
    private let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    private let onePixelJPEG = Data(base64Encoded: "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD9U6KKKAP/2Q==")!

    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipmanImageFileImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testCompliantPNGPreservesExactBytesAndFilename() throws {
        let url = temporaryDirectory.appendingPathComponent("camera original.PNG")
        try onePixelPNG.write(to: url)

        let prepared = try EmbeddedImageFileImport.prepare(urls: [url])

        XCTAssertEqual(prepared.info.data, onePixelPNG)
        XCTAssertEqual(prepared.info.filename, "camera original.png")
        XCTAssertEqual(EmbeddedImageHTML.imageInfo(from: prepared.payload)?.data, onePixelPNG)
    }

    func testCompliantJPEGPreservesExactBytesAndMetadataContainer() throws {
        let url = temporaryDirectory.appendingPathComponent("portrait.jpeg")
        try onePixelJPEG.write(to: url)

        let prepared = try EmbeddedImageFileImport.prepare(urls: [url])

        XCTAssertEqual(prepared.info.data, onePixelJPEG)
        XCTAssertEqual(prepared.info.mimeType, "image/jpeg")
        XCTAssertEqual(prepared.info.filename, "portrait.jpeg")
    }

    func testSelectionMustContainExactlyOneFile() throws {
        let first = temporaryDirectory.appendingPathComponent("first.png")
        let second = temporaryDirectory.appendingPathComponent("second.jpg")
        try onePixelPNG.write(to: first)
        try onePixelJPEG.write(to: second)

        XCTAssertThrowsError(try EmbeddedImageFileImport.prepare(urls: [])) {
            XCTAssertEqual($0 as? EmbeddedImageFileImportError, .noFile)
        }
        XCTAssertThrowsError(try EmbeddedImageFileImport.prepare(urls: [first, second])) {
            XCTAssertEqual($0 as? EmbeddedImageFileImportError, .multipleFiles)
        }
    }

    func testDirectoryAndUnsupportedExtensionAreRejected() throws {
        let directory = temporaryDirectory.appendingPathComponent("folder.png", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unsupported = temporaryDirectory.appendingPathComponent("image.gif")
        try onePixelPNG.write(to: unsupported)

        XCTAssertThrowsError(try EmbeddedImageFileImport.prepare(urls: [directory])) {
            XCTAssertEqual($0 as? EmbeddedImageFileImportError, .directory)
        }
        XCTAssertThrowsError(try EmbeddedImageFileImport.prepare(urls: [unsupported])) {
            XCTAssertEqual($0 as? EmbeddedImageFileImportError, .unsupportedFileType)
        }
    }

    func testOversizedFileIsRejectedBeforeDecode() throws {
        let url = temporaryDirectory.appendingPathComponent("oversized.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(EmbeddedImageHTML.maxInputBytes + 1))
        try handle.close()

        XCTAssertThrowsError(try EmbeddedImageFileImport.prepare(urls: [url])) {
            XCTAssertEqual($0 as? EmbeddedImageFileImportError, .inputTooLarge)
        }
    }

    func testAutomaticCaptureRequiresAllThreeSettings() {
        for richTextEnabled in [false, true] {
            for includeImagesEnabled in [false, true] {
                for automaticFileCaptureEnabled in [false, true] {
                    XCTAssertEqual(
                        EmbeddedImageFileImport.automaticCaptureEnabled(
                            richTextHistoryEnabled: richTextEnabled,
                            includeImagesEnabled: includeImagesEnabled,
                            alsoAddCopiedImageFilesEnabled: automaticFileCaptureEnabled
                        ),
                        richTextEnabled && includeImagesEnabled && automaticFileCaptureEnabled
                    )
                }
            }
        }
    }

    func testOpaqueFinderImageFallbackRequiresOneImageFilenameAndOptIn() {
        XCTAssertTrue(
            EmbeddedImageFileImport.shouldUsePasteboardImageFallback(
                fileReferenceCount: 1,
                plainText: "Screenshot 2026-08-02 at 20.49.11.png",
                automaticCaptureEnabled: true
            )
        )
        XCTAssertTrue(
            EmbeddedImageFileImport.shouldUsePasteboardImageFallback(
                fileReferenceCount: 1,
                plainText: "portrait.JPEG",
                automaticCaptureEnabled: true
            )
        )
    }

    func testOpaqueFinderImageFallbackRejectsAmbiguousClipboardContent() {
        let rejected: [(Int, String?, Bool)] = [
            (1, "Screenshot.png", false),
            (0, "Screenshot.png", true),
            (2, "Screenshot.png", true),
            (1, "https://example.com/Screenshot.png", true),
            (1, "folder/Screenshot.png", true),
            (1, "Screenshot.png\nCopied from Finder", true),
            (1, "Notes.txt", true),
            (1, nil, true)
        ]

        for (count, text, enabled) in rejected {
            XCTAssertFalse(
                EmbeddedImageFileImport.shouldUsePasteboardImageFallback(
                    fileReferenceCount: count,
                    plainText: text,
                    automaticCaptureEnabled: enabled
                )
            )
        }
    }
}
