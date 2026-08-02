import CoreGraphics
import Dispatch
import Foundation
import ImageIO
import ClipmanCore

@discardableResult
func expect(_ condition: @autoclosure () -> Bool, _ message: String) -> Bool {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
    return true
}

func temporaryURL(_ name: String) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipmanCodecSmoke-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name)
}

func createSparseFile(_ url: URL, size: UInt64) throws {
    guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
        throw NSError(domain: "ClipmanCodecSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create a sparse test file."])
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: size)
}

func onePixelTIFF() throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "ClipmanCodecSmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create a TIFF test image."])
    }
    context.setFillColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    guard let image = context.makeImage() else {
        throw NSError(domain: "ClipmanCodecSmoke", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not render a TIFF test image."])
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.tiff" as CFString, 1, nil) else {
        throw NSError(domain: "ClipmanCodecSmoke", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not create a TIFF destination."])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "ClipmanCodecSmoke", code: 5, userInfo: [NSLocalizedDescriptionKey: "Could not finalize a TIFF test image."])
    }
    return data as Data
}

do {
    if let livePath = ProcessInfo.processInfo.environment["CLIPMAN_TEST_DB_PATH"] {
        let password = ProcessInfo.processInfo.environment["CLIPMAN_TEST_DB_PASSWORD"] ?? ""
        let url = URL(fileURLWithPath: livePath)
        let database = try ClipDatabaseFile.load(url, password: password)
        print("Live database loaded: \(database.Entries.count) text entries.")
        exit(0)
    }

    let compressedURL = temporaryURL("roundtrip.clipdb")
    let database = ClipDatabase(Entries: [
        ClipEntry(Text: "hello", Name: "Greeting", SourceMachine: "Mac", Pinned: true, ManualOrder: 1)
    ])
    try ClipDatabaseFile.saveAtomic(compressedURL, database: database)
    let compressedBytes = try Data(contentsOf: compressedURL)
    expect(compressedBytes.starts(with: ClipDatabaseFile.compressedMagic), "compressed file should start with CLIPDB1")
    expect(compressedBytes.count <= ClipDatabaseFile.maximumStoredDatabaseBytes, "a saved compressed database must remain within its reloadable container limit")
    let compressedLoaded = try ClipDatabaseFile.load(compressedURL)
    expect(compressedLoaded.Entries.first?.Text == "hello", "compressed text should round-trip")
    expect(compressedLoaded.Entries.first?.Pinned == true, "pinned state should round-trip")

    expect(Gzip.maximumDecompressedBytes == 256 * 1024 * 1024, "gzip default expansion limit should be 256 MiB")
    expect(ClipDatabaseFile.maximumStoredDatabaseBytes == 272 * 1024 * 1024, "compressed and encrypted client database containers should have an exact 272 MiB compatibility limit")
    expect(ClipDatabaseFile.maximumEncodedJSONBytes == 256 * 1024 * 1024, "encoded and plain JSON should have an exact 256 MiB limit")
    try ClipDatabaseFile.validateContainerInputByteCount(UInt64(ClipDatabaseFile.maximumStoredDatabaseBytes))
    try ClipDatabaseFile.validatePlainJSONInputByteCount(UInt64(ClipDatabaseFile.maximumEncodedJSONBytes))
    try ClipDatabaseFile.validateEncodedJSONByteCount(ClipDatabaseFile.maximumEncodedJSONBytes)
    try ClipDatabaseFile.validateStoredDatabaseByteCount(ClipDatabaseFile.maximumStoredDatabaseBytes)
    do {
        try ClipDatabaseFile.validateContainerInputByteCount(UInt64(ClipDatabaseFile.maximumStoredDatabaseBytes) + 1)
        expect(false, "a container one byte over 272 MiB should fail input validation")
    } catch {
        expect(error as? ClipDatabaseError == .inputTooLarge(ClipDatabaseFile.maximumStoredDatabaseBytes), "container input over the exact limit should report inputTooLarge")
    }
    do {
        try ClipDatabaseFile.validatePlainJSONInputByteCount(UInt64(ClipDatabaseFile.maximumEncodedJSONBytes) + 1)
        expect(false, "plain JSON one byte over 256 MiB should fail input validation")
    } catch {
        expect(error as? ClipDatabaseError == .inputTooLarge(ClipDatabaseFile.maximumEncodedJSONBytes), "plain JSON input over the exact limit should report inputTooLarge")
    }
    do {
        try ClipDatabaseFile.validateEncodedJSONByteCount(ClipDatabaseFile.maximumEncodedJSONBytes + 1)
        expect(false, "encoded JSON one byte over 256 MiB should fail before compression")
    } catch {
        expect(error as? ClipDatabaseError == .encodedJSONTooLarge(ClipDatabaseFile.maximumEncodedJSONBytes), "encoded JSON over the exact limit should report encodedJSONTooLarge")
    }
    do {
        try ClipDatabaseFile.validateStoredDatabaseByteCount(ClipDatabaseFile.maximumStoredDatabaseBytes + 1)
        expect(false, "saved container output one byte over 272 MiB should fail")
    } catch {
        expect(error as? ClipDatabaseError == .outputTooLarge(ClipDatabaseFile.maximumStoredDatabaseBytes), "container output over the exact limit should report outputTooLarge")
    }

    var exactBuffer = try BoundedDataBuffer(maximumBytes: 4, expectedBytes: 4)
    try exactBuffer.append(Data([1, 2, 3, 4]))
    expect(exactBuffer.data == Data([1, 2, 3, 4]), "a bounded response exactly at its byte limit should succeed")
    do {
        try exactBuffer.append(Data([5]))
        expect(false, "a bounded response one byte over its limit should fail before appending")
    } catch {
        expect(error as? BoundedDataBufferError == .limitExceeded(4), "bounded response overflow should report the configured limit")
        expect(exactBuffer.data == Data([1, 2, 3, 4]), "bounded response overflow must not change the accepted data")
    }
    let exactServerBuffer = try BoundedDataBuffer(
        maximumBytes: ClipDatabaseFile.maximumStoredDatabaseBytes,
        expectedBytes: Int64(ClipDatabaseFile.maximumStoredDatabaseBytes)
    )
    expect(exactServerBuffer.data.isEmpty, "an advertised server response exactly at 272 MiB should pass validation without eagerly allocating the full response")
    do {
        _ = try BoundedDataBuffer(maximumBytes: ClipDatabaseFile.maximumStoredDatabaseBytes, expectedBytes: Int64(ClipDatabaseFile.maximumStoredDatabaseBytes) + 1)
        expect(false, "an advertised server response one byte over 272 MiB should fail before allocation")
    } catch {
        expect(error as? BoundedDataBufferError == .limitExceeded(ClipDatabaseFile.maximumStoredDatabaseBytes), "oversized server Content-Length should report the exact 272 MiB client limit")
    }

    let oversizedContainerURL = temporaryURL("oversized.clipdb")
    try createSparseFile(oversizedContainerURL, size: UInt64(ClipDatabaseFile.maximumStoredDatabaseBytes) + 1)
    do {
        _ = try ClipDatabaseFile.load(oversizedContainerURL)
        expect(false, "the bounded reader should reject an oversized container before allocating it")
    } catch {
        expect(error as? ClipDatabaseError == .inputTooLarge(ClipDatabaseFile.maximumStoredDatabaseBytes), "the bounded container reader should report inputTooLarge")
    }
    try? FileManager.default.removeItem(at: oversizedContainerURL.deletingLastPathComponent())

    let oversizedJSONURL = temporaryURL("oversized.json")
    try createSparseFile(oversizedJSONURL, size: UInt64(ClipDatabaseFile.maximumEncodedJSONBytes) + 1)
    do {
        _ = try ClipDatabaseFile.loadCodable(oversizedJSONURL, defaultValue: ClipDatabase())
        expect(false, "the bounded reader should reject oversized plain JSON before allocating it")
    } catch {
        expect(error as? ClipDatabaseError == .inputTooLarge(ClipDatabaseFile.maximumEncodedJSONBytes), "the bounded plain JSON reader should report inputTooLarge")
    }
    try? FileManager.default.removeItem(at: oversizedJSONURL.deletingLastPathComponent())

    let gzipExpansion = Data(repeating: 0x41, count: 256 * 1024)
    let compressedExpansion = try Gzip.compress(gzipExpansion)
    expect(compressedExpansion.count < 1_024, "gzip expansion smoke should use a compact high-ratio payload")
    let exactLimitExpansion = try Gzip.decompress(compressedExpansion, maximumOutputBytes: gzipExpansion.count)
    expect(exactLimitExpansion == gzipExpansion, "gzip output exactly at the configured limit should succeed")
    do {
        _ = try Gzip.decompress(compressedExpansion, maximumOutputBytes: 64 * 1024)
        expect(false, "gzip expansion over the configured limit should fail")
    } catch {
        expect(error as? GzipError == .outputLimitExceeded(64 * 1024), "gzip over-limit expansion should fail with outputLimitExceeded before allocation")
    }

    let encryptedURL = temporaryURL("encrypted.clipdb")
    try ClipDatabaseFile.saveAtomic(encryptedURL, database: ClipDatabase(Entries: [ClipEntry(Text: "secret")]), password: "right")
    let encryptedBytes = try Data(contentsOf: encryptedURL)
    expect(encryptedBytes.starts(with: ClipDatabaseFile.encryptedMagic), "encrypted file should start with CLIPDB2")
    expect(encryptedBytes.count <= ClipDatabaseFile.maximumStoredDatabaseBytes, "a saved encrypted database must remain within its reloadable container limit")
    let encryptedLoaded = try ClipDatabaseFile.load(encryptedURL, password: "right")
    expect(encryptedLoaded.Entries.first?.Text == "secret", "encrypted text should round-trip")
    do {
        _ = try ClipDatabaseFile.load(encryptedURL, password: "wrong")
        expect(false, "wrong encrypted password should fail")
    } catch {
        expect(error as? ClipDatabaseError == .incorrectPassword, "wrong password should report incorrectPassword")
    }

    let plainJSONURL = temporaryURL("plain.json")
    try ClipDatabaseFile.saveAtomic(plainJSONURL, database: database)
    let plainJSONBytes = try Data(contentsOf: plainJSONURL)
    expect(plainJSONBytes.count <= ClipDatabaseFile.maximumEncodedJSONBytes, "saved plain JSON must remain within its reloadable limit")
    let plainJSONLoaded = try ClipDatabaseFile.load(plainJSONURL)
    expect(plainJSONLoaded.Entries.first?.Text == "hello", "a successfully saved plain JSON database should reload")

    expect(WebsiteAddressSafety.allowsLiteralAddress("2606:4700:4700::1"), "an ordinary public IPv6 address ending ::1 should remain allowed")
    expect(WebsiteAddressSafety.allowsLiteralAddress("2606:4700:4700::808:808"), "an ordinary public IPv6 address with a public-looking tail should remain allowed")
    expect(!WebsiteAddressSafety.allowsLiteralAddress("2606:4700:4700::a00:1"), "an otherwise-global IPv6 address ending in 10.0.0.1 should be rejected")
    expect(!WebsiteAddressSafety.allowsLiteralAddress("2606:4700:4700::6440:1"), "an otherwise-global IPv6 address ending in carrier-grade NAT space should be rejected")
    expect(!WebsiteAddressSafety.allowsLiteralAddress("64:ff9b::808:808"), "the well-known NAT64 prefix should remain blocked")
    expect(!WebsiteAddressSafety.allowsLiteralAddress("64:ff9b:1::808:808"), "the local-use NAT64 prefix should remain blocked")
    expect(!WebsiteAddressSafety.allowsLiteralAddress("2002:0808:0808::1"), "6to4 should remain blocked")

    let expiredDeadline = MonotonicDeadline(timeoutSeconds: 0)
    expect(expiredDeadline.isExpired, "a zero-length monotonic deadline should be expired")
    let futureDeadline = MonotonicDeadline(timeoutSeconds: 60)
    expect(!futureDeadline.isExpired, "a future monotonic deadline should not be expired")
    expect(futureDeadline.dispatchTime.uptimeNanoseconds > DispatchTime.now().uptimeNanoseconds, "the monotonic deadline should expose one future uptime target")

    let migrationDirectory = temporaryURL("migration").deletingLastPathComponent()
    let migrationTextURL = migrationDirectory.appendingPathComponent("text.clipdb")
    let migrationFilesURL = migrationDirectory.appendingPathComponent("files.clipdb")
    let migrationSecretsURL = migrationDirectory.appendingPathComponent("secrets.clipdb")
    try ClipDatabaseFile.saveAtomic(
        migrationTextURL,
        database: ClipDatabase(Entries: [ClipEntry(Text: "preserved text")]),
        password: "old-password"
    )
    try ClipDatabaseFile.saveAtomicCodable(
        migrationFilesURL,
        value: FileClipboardDatabase(Events: [FileClipboardEvent(Files: ["/tmp/preserved.txt"])]),
        password: "old-password"
    )
    try ClipDatabaseFile.saveAtomicCodable(
        migrationSecretsURL,
        value: SecretDatabase(Entries: [SecretEntry(Name: "Preserved", Value: "secret value")]),
        password: "old-password"
    )
    try LocalDatabasePasswordMigrator.migrate(
        textHistoryURL: migrationTextURL,
        fileHistoryURL: migrationFilesURL,
        secretsURL: migrationSecretsURL,
        from: "old-password",
        to: "new-password"
    )
    let migratedText = try ClipDatabaseFile.load(migrationTextURL, password: "new-password")
    let migratedFiles = try ClipDatabaseFile.loadCodable(migrationFilesURL, password: "new-password", defaultValue: FileClipboardDatabase())
    let migratedSecrets = try ClipDatabaseFile.loadCodable(migrationSecretsURL, password: "new-password", defaultValue: SecretDatabase())
    expect(migratedText.Entries.first?.Text == "preserved text", "password migration should preserve text history")
    expect(migratedFiles.Events.first?.Files.first == "/tmp/preserved.txt", "password migration should preserve file history")
    expect(migratedSecrets.Entries.first?.Value == "secret value", "password migration should preserve secrets")
    do {
        _ = try ClipDatabaseFile.load(migrationTextURL, password: "old-password")
        expect(false, "old password should not open migrated text history")
    } catch {
        expect(error as? ClipDatabaseError == .incorrectPassword, "old password should be rejected after migration")
    }

    let unknownURL = temporaryURL("unknown.clipdb")
    let json = """
    {
      "Version": 1,
      "UpdatedUnixMs": 10,
      "FutureDatabaseField": "keep me",
      "Entries": [
        {
          "Id": "abc",
          "Text": "entry",
          "Name": "",
          "Group": "",
          "SourceMachine": "Win",
          "CreatedUnixMs": 1,
          "LastUsedUnixMs": 2,
          "Pinned": false,
          "ManualOrder": 1,
          "FutureEntryField": {"Nested": true}
        }
      ]
    }
    """
    let unknownPayload = ClipDatabaseFile.compressedMagic + (try Gzip.compress(Data(json.utf8)))
    try unknownPayload.write(to: unknownURL)
    var unknownDatabase = try ClipDatabaseFile.load(unknownURL)
    unknownDatabase.Entries[0].LastUsedUnixMs = 3
    try ClipDatabaseFile.saveAtomic(unknownURL, database: unknownDatabase)
    let unknownReloaded = try ClipDatabaseFile.load(unknownURL)
    expect(unknownReloaded.unknownFields["FutureDatabaseField"] == .string("keep me"), "database unknown field should be preserved")
    expect(unknownReloaded.Entries[0].unknownFields["FutureEntryField"] == .object(["Nested": .bool(true)]), "entry unknown field should be preserved")

    let linkCases: [(String, String)] = [
        ("https://github.com/OnjLouis/Clipman/issues/50", "Issues 50; github.com/OnjLouis/Clipman/issues/50"),
        ("https://example.com/2024/03/how-to-fix-the-thing", "How to fix the thing; example.com/2024/03/how-to-fix-the-thing"),
        ("https://example.com/", "example.com"),
        ("https://www.example.com/a/b/8f3ac91e-2b1d-4c5a-9f11-6d2e7c0a5b3f", "B; example.com/a/b/8f3ac91e-2b1d-4c5a-9f11-6d2e7c0a5b3f"),
        ("https://example.com/report.pdf", "Report; example.com/report.pdf"),
        ("https://example.com:8443/report", "Report; example.com:8443/report"),
        ("https://docs.python.org/3/library/urllib.parse.html", "Urllib.parse; docs.python.org/3/library/urllib.parse.html"),
        ("https://example.com/a+b", "A+b; example.com/a+b"),
        ("https://example.com/caf%C3%A9", "Café; example.com/café")
    ]
    for (url, expected) in linkCases {
        let actual = LinkPresentation.make(urlText: url)?.rowText
        expect(actual == expected, "link row text should match for \(url); got \(actual ?? "nil")")
    }
    let namedLink = LinkPresentation.make(urlText: "https://example.com/article", assignedName: "Doug proposal")
    expect(namedLink?.rowText == "Doug proposal; example.com/article", "assigned Name should win and retain the destination")
    expect(LinkPresentation.searchableText(urlText: "https://example.com/how-to-test", assignedName: "").contains("How to test"), "search text should contain the generated label")
    expect(LinkPresentation.searchableText(urlText: "https://example.com/how-to-test", assignedName: "Doug proposal").contains("How to test"), "custom Name should not hide the generated label from search")
    let sanitizedLink = LinkPresentation.make(urlText: "https://example.com/folder/%E2%80%AEreport%0A")
    expect(sanitizedLink?.rowText == "Report; example.com/folder/report", "link labels and destinations should strip controls and bidi formatting")
    let maximumURLPrefix = "https://example.com/"
    let maximumURL = maximumURLPrefix + String(
        repeating: "a",
        count: LinkPresentation.maximumURLCharacters - maximumURLPrefix.utf8.count
    )
    expect(LinkPresentation.isURLTextWithinLimit(maximumURL), "a URL exactly at the 8192-character bound should be accepted")
    expect(LinkPresentation.make(urlText: maximumURL) != nil, "offline link presentation should accept an otherwise-valid URL exactly at the bound")
    let oversizedURL = maximumURL + "a"
    expect(!LinkPresentation.isURLTextWithinLimit(oversizedURL), "a URL one character over the bound should be rejected")
    expect(LinkPresentation.make(urlText: oversizedURL) == nil, "offline link presentation must reject an oversized URL before parsing or decoding it")
    let unicodeLink = LinkPresentation.make(
        urlText: "https://example.com/caf%C3%A9%E2%80%8B%EF%BF%BD%E2%80%A8%E6%97%A5%E6%9C%AC%F0%9F%98%80",
        assignedName: "  Café\u{200D}\u{0007} 日本\u{FFFD}\u{2028} 😀  "
    )
    expect(unicodeLink?.label == "Café 日本 😀", "offline labels should remove unsafe scalars while retaining ordinary Unicode")
    expect(unicodeLink?.destination == "example.com/café日本😀", "offline destinations should apply the same unsafe-scalar policy after decoding")

    let sourcesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let appControllerSource = try String(
        contentsOf: sourcesDirectory.appendingPathComponent("Clipman/AppController.swift"),
        encoding: .utf8
    )
    expect(
        appControllerSource.contains("LinkFetchSafety.validatedURL(current.Text, resolveHost: false)"),
        "website-title validation before consent must not resolve the host"
    )
    let serverStorageSource = try String(
        contentsOf: sourcesDirectory.appendingPathComponent("Clipman/ServerStorageClient.swift"),
        encoding: .utf8
    )
    expect(
        serverStorageSource.contains("URLSessionDataDelegate")
            && serverStorageSource.contains("expectedBytes: response.expectedContentLength")
            && serverStorageSource.contains("try buffer.append(data)")
            && !serverStorageSource.contains("dataTask(with: request) {"),
        "HTTPS server downloads must enforce the database limit incrementally instead of completion-handler buffering"
    )
    expect(
        serverStorageSource.contains("body = try BoundedDataBuffer(")
            && serverStorageSource.contains("try body.append(chunk)")
            && serverStorageSource.contains("Database response exceeded the 272 MiB client compatibility limit."),
        "raw HTTP server downloads must enforce the same exact limit with a clear error"
    )
    let titleFetcherSource = try String(
        contentsOf: sourcesDirectory.appendingPathComponent("Clipman/WebsiteTitleFetcher.swift"),
        encoding: .utf8
    )
    expect(
        titleFetcherSource.contains("LinkFetchSafety.validatedTarget(urlText, deadline: deadline)"),
        "confirmed website-title requests must resolve and validate a pinned target"
    )
    guard let fetchLengthGuard = titleFetcherSource.range(of: "guard LinkPresentation.isURLTextWithinLimit(text)"),
          let fetchURLParser = titleFetcherSource.range(of: "let trimmed = text.trimmingCharacters")
    else {
        expect(false, "website-title source should contain the URL bound and parser")
        exit(1)
    }
    expect(fetchLengthGuard.lowerBound < fetchURLParser.lowerBound, "website-title validation must enforce the URL bound before URL parsing")
    guard let redirectLengthGuard = titleFetcherSource.range(of: "LinkPresentation.isURLTextWithinLimit(location)"),
          let redirectURLParser = titleFetcherSource.range(of: "let redirectURL = URL(string: location")
    else {
        expect(false, "website-title redirects should contain the URL bound and parser")
        exit(1)
    }
    expect(redirectLengthGuard.lowerBound < redirectURLParser.lowerBound, "redirect locations must be bounded before URL parsing")
    expect(
        titleFetcherSource.contains("LinkFetchSafety.validatedTarget(redirectURL.absoluteString, deadline: deadline)"),
        "website-title redirects must resolve and validate a new pinned target"
    )
    expect(
        titleFetcherSource.contains("let deadline = MonotonicDeadline(timeoutSeconds: 8)")
            && !titleFetcherSource.contains("Date().addingTimeInterval")
            && !titleFetcherSource.contains("timeIntervalSinceNow"),
        "website-title DNS, requests, and redirects must share one monotonic deadline"
    )
    expect(
        titleFetcherSource.contains("numericAddresses: try resolvedPublicAddresses(host, deadline: deadline)"),
        "website-title targets must carry only addresses returned by public-address validation"
    )
    expect(!titleFetcherSource.contains("URLSession"), "website-title fetching must not pass validated hostnames back to URLSession")
    let pinnedTransportSource = try String(
        contentsOf: sourcesDirectory.appendingPathComponent("Clipman/PinnedHTTPTransport.swift"),
        encoding: .utf8
    )
    expect(
        pinnedTransportSource.contains("deadline: MonotonicDeadline")
            && pinnedTransportSource.contains("completionSignal.wait(timeout: deadline.dispatchTime)")
            && !pinnedTransportSource.contains("timeIntervalSinceNow"),
        "website-title retries and reads must consume the shared monotonic deadline directly"
    )
    expect(
        titleFetcherSource.contains("struct ValidatedNumericAddress") && titleFetcherSource.contains("fileprivate init(_ value: String)"),
        "only DNS safety validation should be able to construct validated numeric addresses"
    )
    expect(
        pinnedTransportSource.contains("PinnedConnectionEndpoint(validatedAddress: validatedAddress)"),
        "website-title transport should accept only resolver-validated numeric addresses"
    )
    expect(
        pinnedTransportSource.contains("networkHost = .ipv4(address)") && pinnedTransportSource.contains("networkHost = .ipv6(address)"),
        "website-title transport targets must be typed numeric IP endpoints"
    )
    expect(
        pinnedTransportSource.contains("NWConnection(host: endpoint.networkHost"),
        "website-title connections must use the validated numeric endpoint"
    )
    expect(
        pinnedTransportSource.contains("sec_protocol_options_set_tls_server_name") && pinnedTransportSource.contains("originalHostname.withCString"),
        "pinned HTTPS transport must validate TLS using the original hostname"
    )
    expect(
        pinnedTransportSource.contains("Accept-Encoding: identity") && pinnedTransportSource.contains("Connection: close"),
        "website-title requests should use bounded identity responses and close the direct connection"
    )
    expect(
        !pinnedTransportSource.contains("Cookie:") && !pinnedTransportSource.contains("Authorization:"),
        "website-title transport must not send cookies or credentials"
    )

    expect(
        LinkDisplayTextSanitizer.normalizedTitle("Café\u{200D}\u{0007} 日本\u{FFFD}\u{2028} 😀") == "Café 日本 😀",
        "fetched titles should strip format, control, replacement, and line-separator scalars while retaining normal Unicode"
    )
    expect(
        LinkDisplayTextSanitizer.normalizedTitle("Safe\u{FFFD}Title") == "SafeTitle",
        "fetched titles should remove replacement characters produced by invalid input"
    )
    expect(
        titleFetcherSource.contains("replacement = \"\"")
            && titleFetcherSource.contains("return LinkDisplayTextSanitizer.normalizedTitle(decoded)"),
        "website-title entity decoding should drop invalid scalar entities before applying the shared title sanitizer"
    )

    let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    let embedded = try EmbeddedImageHTML.makePayload(data: onePixelPNG, filename: "sample.png")
    let finderPNGName = EmbeddedImageFileNaming.suggestedFilename(
        capturedUnixMs: 1_704_164_645_000,
        device: "Andre/Mac:\u{202e} test",
        mimeType: "image/png",
        timeZone: TimeZone(secondsFromGMT: 0)!
    )
    expect(finderPNGName == "Clipman image 2024-01-02 03-04-05 - Andre Mac test.png", "Finder PNG filenames should contain a safe date and device")
    let finderJPEGName = EmbeddedImageFileNaming.suggestedFilename(
        capturedUnixMs: 1_704_164_645_000,
        device: "",
        mimeType: "image/jpeg",
        timeZone: TimeZone(secondsFromGMT: 0)!
    )
    expect(finderJPEGName == "Clipman image 2024-01-02 03-04-05.jpg", "Finder JPEG filenames should use the stored image format")
    expect(embedded.info.data == onePixelPNG, "in-bounds PNG bytes and metadata should be preserved exactly")
    expect(embedded.text == "Image: sample.png (\(String(embedded.info.contentIdentifier.prefix(12))))", "plain image fallback should use the stable filename and final-byte hash")
    expect(embedded.info.altText == "Image: sample.png", "canonical image alt text should expose only the filename")
    let unnamedImage = try EmbeddedImageHTML.makePayload(data: onePixelPNG, filename: "content://provider/private/42")
    expect(unnamedImage.info.filename == "Clipboard image.png", "content-provider identifiers should use the stable clipboard filename")
    let pathImage = try EmbeddedImageHTML.makePayload(data: onePixelPNG, filename: #"C:\Users\Someone\Pictures\photo.png"#)
    expect(pathImage.info.filename == "photo.png", "stored image filenames should be basenames only")
    let colonImage = try EmbeddedImageHTML.makePayload(data: onePixelPNG, filename: "folder:photo.png")
    expect(colonImage.info.filename == "folderphoto.png", "stored image filenames should remove colons")
    let uppercaseImage = try EmbeddedImageHTML.makePayload(data: onePixelPNG, filename: "SCREENSHOT.PNG")
    expect(uppercaseImage.info.filename == "SCREENSHOT.png", "generated PNG filenames should always use a lowercase canonical suffix")
    expect(EmbeddedImageHTML.imageInfo(from: uppercaseImage.payload)?.filename == "SCREENSHOT.png", "lowercase canonical suffixes should round-trip")
    let whitespaceImage = try EmbeddedImageHTML.makePayload(
        data: onePixelPNG,
        filename: "  report\u{00A0}\u{2028}\t\u{3000}final.PNG  "
    )
    expect(whitespaceImage.info.filename == "report final.png", "every run of Unicode whitespace should collapse to one ASCII space")
    expect(EmbeddedImageHTML.imageInfo(from: whitespaceImage.payload)?.filename == "report final.png", "whitespace-normalized wrappers should remain parseable")
    let replacementImage = try EmbeddedImageHTML.makePayload(data: onePixelPNG, filename: "safe\u{FFFD}\u{200D}name.PNG")
    expect(replacementImage.info.filename == "safename.png", "replacement and format scalars should be removed from generated filenames")
    let longImage = try EmbeddedImageHTML.makePayload(data: onePixelPNG, filename: String(repeating: "a", count: 200) + ".png")
    expect(longImage.info.filename.count == 120 && longImage.info.filename.hasSuffix(".png"), "canonical image filenames should include their extension within the 120-character limit")
    expect(EmbeddedImageHTML.imageInfo(from: longImage.payload)?.filename == longImage.info.filename, "long canonical image filenames should remain cross-platform parseable")
    let onePixelJPEG = Data(base64Encoded: "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD9U6KKKAP/2Q==")!
    let jpegImage = try EmbeddedImageHTML.makePayload(data: onePixelJPEG, filename: "portrait.jpeg")
    expect(jpegImage.info.filename == "portrait.jpeg", "a safe existing JPEG .jpeg suffix should be preserved")
    expect(EmbeddedImageHTML.imageInfo(from: jpegImage.payload)?.filename == "portrait.jpeg", "canonical .jpeg wrappers from other platforms should remain parseable")
    let unnamedJPEG = try EmbeddedImageHTML.makePayload(data: onePixelJPEG, filename: "")
    expect(unnamedJPEG.info.filename == "Clipboard image.jpg", "unnamed JPEG fallback should continue to use .jpg")
    let longJPEG = try EmbeddedImageHTML.makePayload(data: onePixelJPEG, filename: String(repeating: "b", count: 200) + ".jpeg")
    expect(longJPEG.info.filename.unicodeScalars.count == 120 && longJPEG.info.filename.hasSuffix(".jpeg"), "the preserved .jpeg suffix should remain within the 120-scalar total limit")
    expect(EmbeddedImageHTML.imageInfo(from: longJPEG.payload)?.filename == longJPEG.info.filename, "long canonical .jpeg filenames should remain parseable")
    let scalarHeavyName = String(repeating: "e\u{301}", count: 80) + ".png"
    let scalarCappedImage = try EmbeddedImageHTML.makePayload(data: onePixelPNG, filename: scalarHeavyName)
    expect(scalarCappedImage.info.filename.unicodeScalars.count == 120, "canonical image filenames should be capped by Unicode scalar count")
    expect(scalarCappedImage.info.filename.hasSuffix(".png"), "Unicode scalar truncation should preserve the image extension")
    expect(EmbeddedImageHTML.imageInfo(from: scalarCappedImage.payload)?.filename == scalarCappedImage.info.filename, "scalar-capped canonical filenames should remain parseable")
    let unsafeUnicodeImage = try EmbeddedImageHTML.makePayload(data: onePixelPNG, filename: "safe\u{200d}\u{202e}\u{0007}name.png")
    expect(unsafeUnicodeImage.info.filename == "safename.png", "generated filenames should remove format, bidi, and control scalars")
    let formatInjectedHTML = embedded.payload.HtmlFragment.replacingOccurrences(of: "sample.png", with: "sam\u{200d}ple.png")
    expect(EmbeddedImageHTML.imageInfo(fromHTML: formatInjectedHTML) == nil, "canonical image parsing should reject format characters in filenames")
    let bidiInjectedHTML = embedded.payload.HtmlFragment.replacingOccurrences(of: "sample.png", with: "sam\u{202e}ple.png")
    expect(EmbeddedImageHTML.imageInfo(fromHTML: bidiInjectedHTML) == nil, "canonical image parsing should reject bidi characters in filenames")
    let controlInjectedHTML = embedded.payload.HtmlFragment.replacingOccurrences(of: "sample.png", with: "sam\u{0007}ple.png")
    expect(EmbeddedImageHTML.imageInfo(fromHTML: controlInjectedHTML) == nil, "canonical image parsing should reject control characters in filenames")
    let uppercaseInjectedHTML = embedded.payload.HtmlFragment.replacingOccurrences(of: "sample.png", with: "sample.PNG")
    expect(EmbeddedImageHTML.imageInfo(fromHTML: uppercaseInjectedHTML) == nil, "canonical image parsing should reject uppercase image suffixes")
    let whitespaceInjectedHTML = embedded.payload.HtmlFragment.replacingOccurrences(of: "sample.png", with: "sample\u{00A0}\u{2028}name.png")
    expect(EmbeddedImageHTML.imageInfo(fromHTML: whitespaceInjectedHTML) == nil, "canonical image parsing should reject non-ASCII or uncollapsed whitespace")
    expect(embedded.info.width == 1 && embedded.info.height == 1, "embedded image dimensions should be retained")
    expect(embedded.payload.HtmlFragment.utf8.count < EmbeddedImageHTML.maxHTMLBytes, "canonical image HTML should remain within the HTML limit")
    let decodedImage = EmbeddedImageHTML.imageInfo(from: embedded.payload)
    expect(decodedImage?.data == onePixelPNG, "canonical embedded image should decode to the original bytes")
    expect(decodedImage?.filename == "sample.png", "canonical embedded image should preserve its filename")
    expect(EmbeddedImageHTML.imageInfo(fromHTML: #"<img src=\"https://example.com/tracker.png\">"#) == nil, "external image wrapper should be rejected")
    expect(EmbeddedImageHTML.imageInfo(fromHTML: embedded.payload.HtmlFragment + "<script>alert(1)</script>") == nil, "active content appended to a wrapper should be rejected")
    expect(EmbeddedImageHTML.imageInfo(fromHTML: embedded.payload.HtmlFragment.replacingOccurrences(of: "data-clipman-image=\"1\"", with: "data-clipman-image=\"0\"")) == nil, "non-canonical wrapper marker should be rejected")
    expect(EmbeddedImageHTML.imageInfo(fromHTML: embedded.payload.HtmlFragment.replacingOccurrences(of: "alt=\"Image: sample.png\"", with: "alt=\"Different text\"")) == nil, "non-canonical image alt text should be rejected")
    expect(EmbeddedImageHTML.imageInfo(fromHTML: embedded.payload.HtmlFragment.replacingOccurrences(of: "sample.png", with: "/private/sample.png")) == nil, "image wrapper filenames containing paths should be rejected")
    let tiffTransport = try onePixelTIFF()
    let convertedTIFF = try EmbeddedImageHTML.pngData(fromTIFFTransport: tiffTransport)
    expect(convertedTIFF.starts(with: Data([0x89, 0x50, 0x4e, 0x47])), "TIFF pasteboard transport should convert to PNG before storage")
    let tiffEmbedded = try EmbeddedImageHTML.makePayload(data: convertedTIFF, filename: "screenshot.tiff")
    expect(tiffEmbedded.info.mimeType == "image/png", "TIFF transport should produce a stored PNG image")
    expect(tiffEmbedded.info.filename == "screenshot.png", "TIFF transport filenames should be normalized to PNG")
    expect(EmbeddedImageHTML.imageInfo(from: tiffEmbedded.payload)?.data == tiffEmbedded.info.data, "converted TIFF transport should round-trip through canonical image storage")
    let richTextDataSource = try String(
        contentsOf: sourcesDirectory.appendingPathComponent("Clipman/RichTextData.swift"),
        encoding: .utf8
    )
    expect(
        richTextDataSource.contains("(.tiff, \"tiff\", true)")
            && richTextDataSource.contains("EmbeddedImageHTML.pngData(fromTIFFTransport: data)"),
        "the Mac pasteboard path should accept TIFF only through the bounded PNG transport conversion"
    )
    do {
        _ = try EmbeddedImageHTML.makePayload(data: Data(repeating: 0, count: EmbeddedImageHTML.maxInputBytes + 1), filename: "large.png")
        expect(false, "image input over 16 MiB should fail")
    } catch {
        expect(error as? EmbeddedImageError == .inputTooLarge, "oversize input should report inputTooLarge")
    }
    do {
        try EmbeddedImageHTML.validateInputDimensions(width: 4097, height: 1)
        expect(false, "image dimension over 4096 should fail")
    } catch {
        expect(error as? EmbeddedImageError == .dimensionsTooLarge, "oversize dimension should report dimensionsTooLarge")
    }
    do {
        try EmbeddedImageHTML.validateInputDimensions(width: 4001, height: 4001)
        expect(false, "image over 16 megapixels should fail")
    } catch {
        expect(error as? EmbeddedImageError == .dimensionsTooLarge, "pixel limit should report dimensionsTooLarge")
    }

    print("Clipman codec smoke tests passed.")
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}
