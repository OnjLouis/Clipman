import ImageIO
import CryptoKit
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Clipman

final class EmbeddedImageTests: XCTestCase {
    func testSmallPNGPreservesOriginalBytesAndRoundTripsCanonicalWrapper() throws {
        let original = try makePNG(width: 20, height: 10)
        let payload = try EmbeddedImageCodec.makePayload(data: original, suggestedFilename: "sample.png")
        let image = try XCTUnwrap(payload.embeddedImage)

        XCTAssertEqual(image.data, original)
        XCTAssertEqual(image.filename, "sample.png")
        XCTAssertEqual(image.altText, "Image: sample.png")
        let hash = SHA256.hash(data: image.data).prefix(6).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(payload.text, "Image: sample.png (\(hash))")
        XCTAssertEqual(EmbeddedImageCodec.displayText(filename: image.filename), "Image: sample.png")
        XCTAssertEqual(image.width, 20)
        XCTAssertEqual(image.height, 10)
        XCTAssertLessThan(payload.richText?.HtmlFragment.utf8.count ?? Int.max, EmbeddedImageCodec.maximumHTMLBytes)
        XCTAssertEqual(EmbeddedImageCodec.recognize(payload.richText), image)
    }

    func testMetadataIsPreservedWhenOriginalJPEGIsAlreadyWithinBounds() throws {
        let original = try makeJPEGWithMetadata()
        let payload = try EmbeddedImageCodec.makePayload(data: original, suggestedFilename: "metadata.jpg")
        let image = try XCTUnwrap(payload.embeddedImage)

        XCTAssertEqual(image.data, original)
        XCTAssertTrue(image.containsMetadata)
    }

    func testOptimizedImageUsesFinalBytesForIdentityAndRetainsBoundedMetadata() throws {
        let original = try makeJPEGWithMetadata(width: 2200, height: 10)
        let payload = try EmbeddedImageCodec.makePayload(data: original, suggestedFilename: "wide.jpg")
        let image = try XCTUnwrap(payload.embeddedImage)
        let finalHash = SHA256.hash(data: image.data).prefix(6).map { String(format: "%02x", $0) }.joined()

        XCTAssertNotEqual(image.data, original)
        XCTAssertLessThanOrEqual(max(image.width, image.height), EmbeddedImageCodec.preferredLongEdge)
        XCTAssertTrue(image.containsMetadata)
        XCTAssertEqual(payload.text, "Image: wide.jpg (\(finalHash))")
    }

    func testWrapperRejectsExternalActiveAndNonCanonicalContent() throws {
        XCTAssertThrowsError(try EmbeddedImageCodec.recognize(html: #"<img data-clipman-image="1" data-clipman-filename="x.png" alt="x" src="https://example.com/x.png">"#))
        XCTAssertThrowsError(try EmbeddedImageCodec.recognize(html: #"<img data-clipman-image="1" data-clipman-filename="x.png" alt="x" onload="alert(1)" src="data:image/png;base64,AA==">"#))
        XCTAssertThrowsError(try EmbeddedImageCodec.recognize(html: #"<img data-clipman-image="1" data-clipman-filename="../x.png" alt="Image: ../x.png" src="data:image/png;base64,AA==">"#))
        XCTAssertNil(MobileRichTextClipboard.normalize(RichTextPayload(HtmlFragment: #"<img data-clipman-image="1" src="data:image/png;base64,AA==">"#)))
    }

    func testFilenameIsBasenameAndProviderIdentifiersUseStableFallback() throws {
        let data = try makePNG(width: 8, height: 8)
        let pathPayload = try EmbeddedImageCodec.makePayload(data: data, suggestedFilename: "/private/photos/holiday.png")
        XCTAssertEqual(pathPayload.embeddedImage?.filename, "holiday.png")

        let providerPayload = try EmbeddedImageCodec.makePayload(data: data, suggestedFilename: "content://photos/opaque-123")
        XCTAssertEqual(providerPayload.embeddedImage?.filename, "Clipboard image.png")
        XCTAssertEqual(providerPayload.embeddedImage?.altText, "Image: Clipboard image.png")
    }

    func testCanonicalFilenameIncludesExtensionWithin120CharacterLimit() throws {
        let data = try makePNG(width: 8, height: 8)
        let suggested = "/private/photos/" + String(repeating: "a", count: 160) + ".png"

        let payload = try EmbeddedImageCodec.makePayload(data: data, suggestedFilename: suggested)
        let filename = try XCTUnwrap(payload.embeddedImage?.filename)

        XCTAssertEqual(filename.unicodeScalars.count, 120)
        XCTAssertTrue(filename.hasSuffix(".png"))
        XCTAssertFalse(filename.contains("/"))

        let decomposed = String(repeating: "e\u{301}", count: 100) + ".png"
        let unicodePayload = try EmbeddedImageCodec.makePayload(data: data, suggestedFilename: decomposed)
        let unicodeFilename = try XCTUnwrap(unicodePayload.embeddedImage?.filename)
        XCTAssertLessThanOrEqual(unicodeFilename.unicodeScalars.count, 120)
        XCTAssertTrue(unicodeFilename.hasSuffix(".png"))
    }

    func testCanonicalFilenameCollapsesUnicodeWhitespaceAndLowercasesSuffix() throws {
        let data = try makePNG(width: 8, height: 8)
        let payload = try EmbeddedImageCodec.makePayload(
            data: data,
            suggestedFilename: "  report\t\u{00A0}\u{2003}\u{2028}\u{2029}final.PNG  "
        )
        XCTAssertEqual(payload.embeddedImage?.filename, "report final.png")
        XCTAssertEqual(EmbeddedImageCodec.recognize(payload.richText)?.filename, "report final.png")

        let unsafe = try EmbeddedImageCodec.makePayload(
            data: data,
            suggestedFilename: "safe\u{200D}\u{202E}\u{0007}:name.PNG"
        )
        XCTAssertEqual(unsafe.embeddedImage?.filename, "safename.png")

        let nonWhitespaceControl = try EmbeddedImageCodec.makePayload(
            data: data,
            suggestedFilename: "safe\u{001C}name.PNG"
        )
        XCTAssertEqual(nonWhitespaceControl.embeddedImage?.filename, "safename.png")

        let jpeg = try EmbeddedImageCodec.makePayload(
            data: try makeJPEGWithMetadata(),
            suggestedFilename: "PORTRAIT.JPEG"
        )
        XCTAssertEqual(jpeg.embeddedImage?.filename, "PORTRAIT.jpeg")
    }

    func testParserRequiresExactCanonicalFilenameWhitespaceAndSuffix() throws {
        let payload = try EmbeddedImageCodec.makePayload(
            data: try makePNG(width: 8, height: 8),
            suggestedFilename: "photo note.png"
        )
        let html = try XCTUnwrap(payload.richText?.HtmlFragment)
        for noncanonical in [
            "photo  note.png",
            " photo note.png",
            "photo\u{00A0}note.png",
            "photo\u{2028}note.png",
            "photo note.PNG",
            "photo:note.png"
        ] {
            XCTAssertThrowsError(try EmbeddedImageCodec.recognize(
                html: html.replacingOccurrences(of: "photo note.png", with: noncanonical)
            ))
        }
    }

    func testWrapperRejectsOversizedEncodedDataBeforeDecodeAndMismatchedExtensions() throws {
        let oversizedBase64 = String(repeating: "A", count: EmbeddedImageCodec.maximumEncodedImageBytes + 4)
        let unpaddedBoundary = String(repeating: "A", count: EmbeddedImageCodec.maximumEncodedImageBytes)
        let paddedBoundary = String(repeating: "A", count: EmbeddedImageCodec.maximumEncodedImageBytes - 1) + "="
        XCTAssertFalse(EmbeddedImageCodec.encodedImageLengthIsWithinLimit(oversizedBase64[...]))
        XCTAssertFalse(EmbeddedImageCodec.encodedImageLengthIsWithinLimit(unpaddedBoundary[...]))
        XCTAssertTrue(EmbeddedImageCodec.encodedImageLengthIsWithinLimit(paddedBoundary[...]))
        let oversized = #"<img data-clipman-image="1" data-clipman-filename="x.png" alt="Image: x.png" src="data:image/png;base64,"#
            + oversizedBase64 + #"">"#
        XCTAssertThrowsError(try EmbeddedImageCodec.recognize(html: oversized))

        let payload = try EmbeddedImageCodec.makePayload(data: try makePNG(width: 8, height: 8), suggestedFilename: "sample.png")
        let html = try XCTUnwrap(payload.richText?.HtmlFragment)
        let mismatched = html.replacingOccurrences(of: "sample.png", with: "sample.jpg")
        XCTAssertThrowsError(try EmbeddedImageCodec.recognize(html: mismatched))
    }

    func testWrapperRejectsUnicodeFormatCharactersAndNonCanonicalRebuilds() throws {
        let payload = try EmbeddedImageCodec.makePayload(data: try makePNG(width: 8, height: 8), suggestedFilename: "sample.png")
        let html = try XCTUnwrap(payload.richText?.HtmlFragment)
        let formatCharacter = html.replacingOccurrences(of: "sample.png", with: "sam\u{200D}ple.png")
        XCTAssertThrowsError(try EmbeddedImageCodec.recognize(html: formatCharacter))
        XCTAssertThrowsError(try EmbeddedImageCodec.recognize(html: html + "\n"))
    }

    func testFilenameRejectsReplacementCharactersAndRepairedUnpairedSurrogates() throws {
        let data = try makePNG(width: 8, height: 8)
        XCTAssertThrowsError(try EmbeddedImageCodec.makePayload(
            data: data,
            suggestedFilename: "bad\u{FFFD}.png"
        )) { error in
            XCTAssertEqual(error as? EmbeddedImageError, .invalidWrapper)
        }

        let repaired = String(decoding: [UInt16(0x0062), 0x0061, 0x0064, 0xd800], as: UTF16.self) + ".png"
        XCTAssertTrue(repaired.unicodeScalars.contains(where: { $0.value == 0xfffd }))
        XCTAssertThrowsError(try EmbeddedImageCodec.makePayload(data: data, suggestedFilename: repaired))

        let payload = try EmbeddedImageCodec.makePayload(data: data, suggestedFilename: "sample.png")
        let html = try XCTUnwrap(payload.richText?.HtmlFragment)
        XCTAssertThrowsError(try EmbeddedImageCodec.recognize(
            html: html.replacingOccurrences(of: "sample.png", with: "bad\u{FFFD}.png")
        ))
    }

    func testMalformedJSONSurrogateEscapeIsRejectedOnDatabaseLoad() throws {
        let malformedJSON = Data(#"{"Entries":[{"Text":"\uD800"}]}"#.utf8)
        let file = ClipDatabaseFile.compressedMagic + (try Gzip.compress(malformedJSON))

        XCTAssertThrowsError(try ClipDatabaseFile.load(file, password: ""))
    }

    func testGzipDecompressionHasABoundedOutput() throws {
        let original = Data(repeating: 0x41, count: 4 * 1024)
        let compressed = try Gzip.compress(original)

        XCTAssertEqual(try Gzip.compress(original, maximumOutputBytes: compressed.count), compressed)
        XCTAssertThrowsError(try Gzip.compress(original, maximumOutputBytes: compressed.count - 1)) { error in
            XCTAssertEqual(error as? GzipError, .compressedOutputTooLarge)
        }
        XCTAssertEqual(try Gzip.decompress(compressed), original)
        XCTAssertThrowsError(try Gzip.decompress(compressed, maximumOutputBytes: 1024)) { error in
            XCTAssertEqual(error as? GzipError, .outputTooLarge)
        }
    }

    func testDatabaseSizeBoundariesAcceptExactAndRejectOverLimit() {
        XCTAssertNoThrow(try ClipDatabaseFile.validateFileSize(ClipDatabaseFile.maximumFileBytes))
        XCTAssertThrowsError(try ClipDatabaseFile.validateFileSize(ClipDatabaseFile.maximumFileBytes + 1)) { error in
            XCTAssertEqual(error as? ClipDatabaseError, .databaseFileTooLarge)
        }
        XCTAssertNoThrow(try ClipDatabaseFile.validateEncodedJSONSize(ClipDatabaseFile.maximumEncodedJSONBytes))
        XCTAssertThrowsError(try ClipDatabaseFile.validateEncodedJSONSize(ClipDatabaseFile.maximumEncodedJSONBytes + 1)) { error in
            XCTAssertEqual(error as? ClipDatabaseError, .encodedDatabaseTooLarge)
        }
    }

    func testSavedDatabaseCanReloadAtBothEncryptionModes() throws {
        let database = ClipDatabase(
            Version: 1,
            UpdatedUnixMs: 123,
            Entries: [ClipEntry(
                Id: "entry",
                Text: "Round-trip text",
                Name: "Round trip",
                CreatedUnixMs: 100,
                LastUsedUnixMs: 110,
                ModifiedUnixMs: 120
            )]
        )

        for password in ["", "correct horse battery staple"] {
            let saved = try ClipDatabaseFile.save(database, password: password)
            XCTAssertLessThanOrEqual(saved.count, ClipDatabaseFile.maximumFileBytes)
            XCTAssertEqual(try ClipDatabaseFile.load(saved, password: password), database)
        }
    }

    func testBoundedFileAndNetworkBuffersStopAtTheirLimits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.clipdb")
        try Data([1, 2, 3, 4]).write(to: file)
        XCTAssertEqual(try ClipDatabaseFile.readBounded(from: file, maximumBytes: 4), Data([1, 2, 3, 4]))
        try Data([1, 2, 3, 4, 5]).write(to: file)
        XCTAssertThrowsError(try ClipDatabaseFile.readBounded(from: file, maximumBytes: 4))

        XCTAssertTrue(BoundedResponseBuffer.accepts(
            expectedContentLength: Int64(ClipDatabaseFile.maximumFileBytes),
            maximumBytes: ClipDatabaseFile.maximumFileBytes
        ))
        XCTAssertFalse(BoundedResponseBuffer.accepts(
            expectedContentLength: Int64(ClipDatabaseFile.maximumFileBytes + 1),
            maximumBytes: ClipDatabaseFile.maximumFileBytes
        ))
        var buffer = BoundedResponseBuffer(maximumBytes: 4)
        try buffer.append(Data([1, 2]))
        try buffer.append(Data([3, 4]))
        XCTAssertEqual(buffer.data, Data([1, 2, 3, 4]))
        XCTAssertThrowsError(try buffer.append(Data([5]))) { error in
            XCTAssertEqual(error as? BoundedResponseError, .responseTooLarge)
        }
    }

    func testInputAndDimensionLimitsAreEnforced() throws {
        XCTAssertThrowsError(try EmbeddedImageCodec.makePayload(data: Data(count: EmbeddedImageCodec.maximumInputBytes + 1))) { error in
            XCTAssertEqual(error as? EmbeddedImageError, .inputTooLarge)
        }
        let tooWide = try makePNG(width: EmbeddedImageCodec.maximumInputDimension + 1, height: 1)
        XCTAssertThrowsError(try EmbeddedImageCodec.makePayload(data: tooWide)) { error in
            XCTAssertEqual(error as? EmbeddedImageError, .dimensionsTooLarge)
        }
    }

    @MainActor
    func testCopyPublishesNativeImagePlainTextAndSafeHTML() throws {
        let payload = try EmbeddedImageCodec.makePayload(data: try makePNG(width: 8, height: 8))
        let image = try XCTUnwrap(payload.embeddedImage)
        let pasteboardName = UIPasteboard.Name("ClipmanIOSTests.\(UUID().uuidString)")
        let pasteboard = try XCTUnwrap(UIPasteboard(name: pasteboardName, create: true))
        defer { UIPasteboard.remove(withName: pasteboardName) }
        let entry = ClipEntry(Text: payload.text, RichText: payload.richText)

        MobileRichTextClipboard.write(entry, includeRichText: true, to: pasteboard)

        XCTAssertEqual(
            pasteboard.data(forPasteboardType: UTType.utf8PlainText.identifier).flatMap { String(data: $0, encoding: .utf8) },
            payload.text
        )
        XCTAssertEqual(pasteboard.data(forPasteboardType: UTType.png.identifier), image.data)
        XCTAssertEqual(
            pasteboard.data(forPasteboardType: UTType.html.identifier),
            payload.richText?.HtmlFragment.data(using: .utf8)
        )
    }

    @MainActor
    func testCopyRestoresNativeImageWhenRichTextCaptureIsDisabled() throws {
        let payload = try EmbeddedImageCodec.makePayload(data: try makePNG(width: 8, height: 8))
        let image = try XCTUnwrap(payload.embeddedImage)
        let pasteboardName = UIPasteboard.Name("ClipmanIOSTests.\(UUID().uuidString)")
        let pasteboard = try XCTUnwrap(UIPasteboard(name: pasteboardName, create: true))
        defer { UIPasteboard.remove(withName: pasteboardName) }
        let entry = ClipEntry(Text: payload.text, RichText: payload.richText)

        MobileRichTextClipboard.write(entry, includeRichText: false, to: pasteboard)

        XCTAssertEqual(pasteboard.data(forPasteboardType: UTType.png.identifier), image.data)
        XCTAssertEqual(
            pasteboard.data(forPasteboardType: UTType.html.identifier),
            payload.richText?.HtmlFragment.data(using: .utf8)
        )
        XCTAssertEqual(pasteboard.string, payload.text)
    }

    @MainActor
    func testCopyRestoresNativeJPEGWhenRichTextCaptureIsDisabled() throws {
        let payload = try EmbeddedImageCodec.makePayload(
            data: try makeJPEGWithMetadata(),
            suggestedFilename: "photo.jpg"
        )
        let image = try XCTUnwrap(payload.embeddedImage)
        let pasteboardName = UIPasteboard.Name("ClipmanIOSTests.\(UUID().uuidString)")
        let pasteboard = try XCTUnwrap(UIPasteboard(name: pasteboardName, create: true))
        defer { UIPasteboard.remove(withName: pasteboardName) }

        MobileRichTextClipboard.write(
            ClipEntry(Text: payload.text, RichText: payload.richText),
            includeRichText: false,
            to: pasteboard
        )

        XCTAssertEqual(pasteboard.data(forPasteboardType: UTType.jpeg.identifier), image.data)
        XCTAssertEqual(
            pasteboard.data(forPasteboardType: UTType.html.identifier),
            payload.richText?.HtmlFragment.data(using: .utf8)
        )
        XCTAssertEqual(pasteboard.string, payload.text)
    }

    func testCanonicalHTMLImportRetainsFinalByteIdentity() throws {
        let original = try EmbeddedImageCodec.makePayload(data: try makePNG(width: 9, height: 9), suggestedFilename: "icon.png")
        let htmlData = try XCTUnwrap(original.richText?.HtmlFragment.data(using: .utf8))

        let imported = MobileClipboardPayload.payload(fromHTMLData: htmlData)

        XCTAssertEqual(imported.text, original.text)
        XCTAssertEqual(imported.embeddedImage, original.embeddedImage)
    }

    @MainActor
    func testStandaloneNativeImageWinsOverPlainProviderText() throws {
        let data = try makePNG(width: 10, height: 10)
        let pasteboardName = UIPasteboard.Name("ClipmanIOSTests.\(UUID().uuidString)")
        let pasteboard = try XCTUnwrap(UIPasteboard(name: pasteboardName, create: true))
        defer { UIPasteboard.remove(withName: pasteboardName) }
        pasteboard.setItems([[
            UTType.png.identifier: data,
            UTType.plainText.identifier: "opaque provider value"
        ]])

        let imported = try XCTUnwrap(MobileRichTextClipboard.readCurrent(includeImages: true, in: pasteboard))

        XCTAssertNotNil(imported.embeddedImage)
        XCTAssertTrue(imported.text.hasPrefix("Image: Clipboard image.png ("))
    }

    func testDatabaseImageBudgetCountsCanonicalImagesOnly() throws {
        let payload = try EmbeddedImageCodec.makePayload(data: try makePNG(width: 12, height: 12))
        let bytes = try XCTUnwrap(payload.embeddedImage).data.count
        let database = ClipDatabase(Entries: [
            ClipEntry(Text: "first", RichText: payload.richText),
            ClipEntry(Text: "second", RichText: payload.richText),
            ClipEntry(Text: "ordinary", RichText: RichTextPayload(HtmlFragment: "<b>Text</b>"))
        ])

        XCTAssertEqual(EmbeddedImageCodec.totalStoredBytes(in: database), bytes * 2)
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.pngData { context in
            UIColor.systemBlue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func makeJPEGWithMetadata(width: Int = 16, height: Int = 16) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { context in
            UIColor.systemGreen.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Clipman Tests"],
            kCGImageDestinationLossyCompressionQuality: 0.8
        ]
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
