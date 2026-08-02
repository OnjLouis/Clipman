import Darwin
import XCTest
@testable import Clipman

final class LinkDisplayTests: XCTestCase {
    func testGeneratedLabelUsesLastMeaningfulDecodedSegmentWithoutDuplicatingHost() throws {
        let url = try XCTUnwrap(URL(string: "https://www.example.com/guides/using%20clipman-now?tokenless=yes"))
        let info = LinkDisplay.info(for: url)

        XCTAssertEqual(info.generatedLabel, "Using clipman now")
        XCTAssertEqual(info.shortenedDestination, "example.com/guides/using clipman-now")
        XCTAssertEqual(LinkDisplay.rowText(for: url, name: ""), "Using clipman now; example.com/guides/using clipman-now")
    }

    func testGeneratedLabelSkipsUUIDAndHighEntropySegments() throws {
        let uuidURL = try XCTUnwrap(URL(string: "https://www.example.com/articles/550e8400-e29b-41d4-a716-446655440000"))
        XCTAssertEqual(LinkDisplay.info(for: uuidURL).generatedLabel, "Articles")

        let tokenURL = try XCTUnwrap(URL(string: "https://example.com/download/AbCdEf0123456789GhIjKlMnOpQr"))
        XCTAssertEqual(LinkDisplay.info(for: tokenURL).generatedLabel, "Download")
    }

    func testExactCrossPlatformRowContract() throws {
        let issue = try XCTUnwrap(URL(string: "https://github.com/OnjLouis/Clipman/issues/50"))
        XCTAssertEqual(LinkDisplay.rowText(for: issue, name: ""), "Issues 50; github.com/OnjLouis/Clipman/issues/50")

        let dated = try XCTUnwrap(URL(string: "https://example.com/2024/03/how-to-fix-the-thing"))
        XCTAssertEqual(LinkDisplay.rowText(for: dated, name: ""), "How to fix the thing; example.com/2024/03/how-to-fix-the-thing")

        let root = try XCTUnwrap(URL(string: "https://www.example.com/"))
        XCTAssertEqual(LinkDisplay.rowText(for: root, name: ""), "example.com")
        XCTAssertEqual(LinkDisplay.rowText(for: issue, name: " Doug proposal "), "Doug proposal; github.com/OnjLouis/Clipman/issues/50")
    }

    func testWebsiteTitleTargetRequiresTheEntireEntryToMatchOneSelectedLink() throws {
        let selected = try XCTUnwrap(URL(string: "https://example.com/article"))
        XCTAssertTrue(LinkExtractor.isExactWebsiteTitleTarget(
            ClipEntry(Text: "  https://example.com/article  "),
            matching: selected
        ))
        XCTAssertFalse(LinkExtractor.isExactWebsiteTitleTarget(
            ClipEntry(Text: "Read https://example.com/article"),
            matching: selected
        ))
        XCTAssertFalse(LinkExtractor.isExactWebsiteTitleTarget(
            ClipEntry(Text: "https://example.com/article https://example.com/other"),
            matching: selected
        ))
        XCTAssertFalse(LinkExtractor.isExactWebsiteTitleTarget(
            ClipEntry(Text: "https://example.com/other"),
            matching: selected
        ))
        XCTAssertFalse(LinkExtractor.isExactWebsiteTitleTarget(
            ClipEntry(Text: "clipman://example.com/article"),
            matching: try XCTUnwrap(URL(string: "clipman://example.com/article"))
        ))

        let richTextEntry = ClipEntry(
            Text: "https://example.com/article",
            RichText: RichTextPayload(HtmlFragment: "<a href=\"https://example.com/article\">Article</a>")
        )
        XCTAssertEqual(LinkExtractor.exactHTTPURL(in: richTextEntry), selected)
        XCTAssertEqual(LinkDisplay.rowText(for: selected, name: richTextEntry.Name), "Article; example.com/article")
        XCTAssertEqual(richTextEntry.displayText, "Article; example.com/article")
    }

    func testWebsiteTitleParserPrefersOpenGraphAndSanitizesOutput() {
        let html = """
        <html><head>
        <title>Fallback title</title>
        <meta content="  Better &amp; safer\u{202E} title  " property="og:title">
        <meta name="twitter:title" content="Twitter title">
        </head></html>
        """

        XCTAssertEqual(WebsiteTitleParser.title(from: html), "Better & safer title")
    }

    func testOfflineLabelsAndFetchedTitlesStripUnsafeUnicodeConsistently() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/alpha%0Abeta%E2%80%8Dgamma%EF%BF%BDdelta"))
        XCTAssertEqual(
            LinkDisplay.rowText(for: url, name: "  Named\u{0009}entry\u{200D}\u{FFFD}\u{2028}\u{2029}  "),
            "Namedentry; example.com/alphabetagammadelta"
        )

        let html = "<title>Alpha\u{000A}Beta\u{200D}Gamma\u{FFFD}Delta\u{2028}Epsilon\u{2029}Zeta\u{00A0} Eta</title>"
        XCTAssertEqual(WebsiteTitleParser.title(from: html), "AlphaBetaGammaDeltaEpsilonZeta Eta")
    }

    func testOverlongURLsAreRejectedBeforeExtractionOrWebsiteWork() async throws {
        let prefix = "https://example.com/"
        let exact = prefix + String(repeating: "a", count: LinkPresentationSafety.maximumURLScalars - prefix.unicodeScalars.count)
        XCTAssertEqual(exact.unicodeScalars.count, LinkPresentationSafety.maximumURLScalars)
        XCTAssertEqual(LinkExtractor.links(in: exact).count, 1)
        let raw = exact + "a"
        let url = try XCTUnwrap(URL(string: raw))
        XCTAssertTrue(LinkExtractor.links(in: raw).isEmpty)
        XCTAssertEqual(LinkDisplay.info(for: url), LinkDisplayInfo(generatedLabel: "Link", shortenedDestination: "Link"))
        XCTAssertThrowsError(try WebsiteTitlePolicy.validateStructure(url))
        XCTAssertThrowsError(try WebsiteTitleConnectionPlan(
            url: url,
            address: WebsiteTitleResolvedAddress(text: "93.184.216.34", family: AF_INET)
        ))
        XCTAssertThrowsError(try WebsiteTitleRequestBuilder.request(for: url))

        let recorder = WebsiteTitleHopRecorder()
        do {
            _ = try await WebsiteTitleFetcher.fetchTitle(
                for: url,
                resolveAddresses: { host in
                    await recorder.recordResolution(host)
                    return [WebsiteTitleResolvedAddress(text: "93.184.216.34", family: AF_INET)]
                },
                fetchResponse: { _, _, _ in
                    XCTFail("Network work was attempted for an overlong URL")
                    throw WebsiteTitleError.unavailable
                }
            )
            XCTFail("Overlong URL was accepted")
        } catch {
            XCTAssertEqual(error as? WebsiteTitleError, .unsupportedURL)
        }
        let snapshot = await recorder.snapshot()
        XCTAssertTrue(snapshot.resolutions.isEmpty)
    }

    func testOverlongRedirectIsRejectedBeforeAnotherHop() async throws {
        let start = try XCTUnwrap(URL(string: "https://start.example/article"))
        let overlongLocation = "https://final.example/" + String(repeating: "b", count: 8_193)
        let recorder = WebsiteTitleHopRecorder()

        do {
            _ = try await WebsiteTitleFetcher.fetchTitle(
                for: start,
                resolveAddresses: { host in
                    await recorder.recordResolution(host)
                    return [WebsiteTitleResolvedAddress(text: "93.184.216.34", family: AF_INET)]
                },
                fetchResponse: { _, _, _ in
                    WebsiteTitleWireResponse(
                        statusCode: 302,
                        headers: ["location": overlongLocation],
                        body: Data(),
                        bodyWasTruncated: false
                    )
                }
            )
            XCTFail("Overlong redirect was accepted")
        } catch {
            XCTAssertTrue(error is WebsiteTitleError)
        }
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.resolutions, ["start.example"])
    }

    func testEveryRedirectHopRejectsHTTPSDowngrade() throws {
        let http = try XCTUnwrap(URL(string: "http://example.com/start"))
        let https = try XCTUnwrap(URL(string: "https://example.com/secure"))
        let downgraded = try XCTUnwrap(URL(string: "http://example.com/final"))

        XCTAssertFalse(WebsiteTitleRedirectPolicy.rejectsDowngrade(from: http, to: https))
        XCTAssertTrue(WebsiteTitleRedirectPolicy.rejectsDowngrade(from: https, to: downgraded))
        XCTAssertFalse(WebsiteTitleRedirectPolicy.rejectsDowngrade(from: https, to: https))
    }

    func testWebsiteTitlePolicyRejectsSensitiveAndPrivateAddressesWithoutNetworkAccess() throws {
        XCTAssertThrowsError(try WebsiteTitlePolicy.validate(try XCTUnwrap(URL(string: "https://user@example.com/page"))))
        XCTAssertThrowsError(try WebsiteTitlePolicy.validate(try XCTUnwrap(URL(string: "https://127.0.0.1/page"))))
        XCTAssertThrowsError(try WebsiteTitlePolicy.validate(try XCTUnwrap(URL(string: "https://192.31.196.1/page"))))
        XCTAssertThrowsError(try WebsiteTitlePolicy.validate(try XCTUnwrap(URL(string: "https://[2001:db8::1]/page"))))
        XCTAssertThrowsError(try WebsiteTitlePolicy.validate(try XCTUnwrap(URL(string: "https://example.com:8443/page"))))
        XCTAssertThrowsError(try WebsiteTitlePolicy.validate(try XCTUnwrap(URL(string: "https://example.com/reset-password"))))
        XCTAssertThrowsError(try WebsiteTitlePolicy.validate(try XCTUnwrap(URL(string: "https://example.com/page?token=abc"))))
        XCTAssertThrowsError(try WebsiteTitlePolicy.validate(try XCTUnwrap(URL(string: "https://example.com/page?session_token=abc"))))
    }

    func testIPv6EmbeddedPrivateTailDefenseKeepsOrdinaryDoubleColonOnePublic() throws {
        for address in [
            "2001:4860::a00:1",
            "2001:4860::6440:1",
            "2001:4860::7f00:1",
            "2001:4860::a9fe:101",
            "2001:4860::ac10:1",
            "2001:4860::c0a8:101"
        ] {
            XCTAssertFalse(PublicNetworkAddressResolver.isPublicIPv6(try ipv6Bytes(address)), address)
        }

        XCTAssertTrue(PublicNetworkAddressResolver.isPublicIPv6(try ipv6Bytes("2001:4860::1")))
        XCTAssertFalse(PublicNetworkAddressResolver.isPublicIPv6(try ipv6Bytes("64:ff9b::1")))
        XCTAssertFalse(PublicNetworkAddressResolver.isPublicIPv6(try ipv6Bytes("64:ff9b::a00:1")))
        XCTAssertTrue(PublicNetworkAddressResolver.isPublicIPv6(try ipv6Bytes("64:ff9b::808:808")))
        XCTAssertFalse(PublicNetworkAddressResolver.isPublicIPv6(try ipv6Bytes("64:ff9b:1::808:808")))
        XCTAssertFalse(PublicNetworkAddressResolver.isPublicIPv6(try ipv6Bytes("2002:0808:0808::1")))
    }

    func testPinnedConnectionUsesValidatedNumericAddressAndOriginalTLSHost() throws {
        let url = try XCTUnwrap(URL(string: "https://www.example.com/path?q=plain"))
        let address = WebsiteTitleResolvedAddress(text: "93.184.216.34", family: AF_INET)
        let plan = try WebsiteTitleConnectionPlan(url: url, address: address)

        XCTAssertEqual(plan.numericAddress, "93.184.216.34")
        XCTAssertEqual(plan.originalHost, "www.example.com")
        XCTAssertEqual(plan.port, 443)
        XCTAssertTrue(plan.usesTLS)

        let request = try XCTUnwrap(String(data: WebsiteTitleRequestBuilder.request(for: url), encoding: .utf8))
        XCTAssertTrue(request.hasPrefix("GET /path?q=plain HTTP/1.1\r\n"))
        XCTAssertTrue(request.contains("\r\nHost: www.example.com\r\n"))
        XCTAssertTrue(request.contains("\r\nAccept-Encoding: identity\r\n"))
        XCTAssertFalse(request.localizedCaseInsensitiveContains("cookie:"))
        XCTAssertFalse(request.localizedCaseInsensitiveContains("authorization:"))
        XCTAssertFalse(request.localizedCaseInsensitiveContains("referer:"))
    }

    func testEveryRedirectIsResolvedAndPinnedAsANewHop() async throws {
        let start = try XCTUnwrap(URL(string: "https://start.example/article"))
        let destination = try XCTUnwrap(URL(string: "https://final.example/story"))
        let recorder = WebsiteTitleHopRecorder()

        let title = try await WebsiteTitleFetcher.fetchTitle(
            for: start,
            resolveAddresses: { host in
                await recorder.recordResolution(host)
                let address = host == "start.example" ? "93.184.216.34" : "93.184.216.35"
                return [WebsiteTitleResolvedAddress(text: address, family: AF_INET)]
            },
            fetchResponse: { url, addresses, request in
                let plan = try WebsiteTitleConnectionPlan(url: url, address: try XCTUnwrap(addresses.first))
                await recorder.recordConnection(numericAddress: plan.numericAddress, originalHost: plan.originalHost)
                let requestText = try XCTUnwrap(String(data: request, encoding: .utf8))
                XCTAssertTrue(requestText.contains("\r\nHost: \(plan.originalHost)\r\n"))
                if url == start {
                    return WebsiteTitleWireResponse(
                        statusCode: 302,
                        headers: ["location": destination.absoluteString],
                        body: Data(),
                        bodyWasTruncated: false
                    )
                }
                return WebsiteTitleWireResponse(
                    statusCode: 200,
                    headers: ["content-type": "text/html; charset=utf-8"],
                    body: Data("<title>Final title</title>".utf8),
                    bodyWasTruncated: false
                )
            }
        )

        XCTAssertEqual(title, "Final title")
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.resolutions, ["start.example", "final.example"])
        XCTAssertEqual(snapshot.connections, [
            "93.184.216.34|start.example",
            "93.184.216.35|final.example"
        ])
    }

    private func ipv6Bytes(_ address: String) throws -> [UInt8] {
        var value = in6_addr()
        guard inet_pton(AF_INET6, address, &value) == 1 else {
            throw NSError(domain: "LinkDisplayTests", code: 1)
        }
        return withUnsafeBytes(of: value) { Array($0) }
    }
}

final class DatabaseContainerLimitTests: XCTestCase {
    func testContainerAndDecodedLimitsAcceptCapAndRejectCapPlusOne() throws {
        XCTAssertEqual(ClipDatabaseFile.maximumFileBytes, 272 * 1024 * 1024)
        XCTAssertEqual(ClipDatabaseFile.maximumEncodedJSONBytes, 256 * 1024 * 1024)
        XCTAssertEqual(CloudHistoryBackup.maximumBackupBytes, ClipDatabaseFile.maximumFileBytes)
        XCTAssertNoThrow(try ClipDatabaseFile.validateFileSize(ClipDatabaseFile.maximumFileBytes))
        XCTAssertThrowsError(try ClipDatabaseFile.validateFileSize(ClipDatabaseFile.maximumFileBytes + 1)) {
            XCTAssertEqual($0 as? ClipDatabaseError, .databaseFileTooLarge)
        }
        XCTAssertNoThrow(try ClipDatabaseFile.validateEncodedJSONSize(ClipDatabaseFile.maximumEncodedJSONBytes))
        XCTAssertThrowsError(try ClipDatabaseFile.validateEncodedJSONSize(ClipDatabaseFile.maximumEncodedJSONBytes + 1)) {
            XCTAssertEqual($0 as? ClipDatabaseError, .encodedDatabaseTooLarge)
        }
    }

    func testLocalAndServerReadersAcceptExactBoundAndRejectOneExtraByte() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipman-bounded-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.clipdb")
        try Data(repeating: 0x41, count: 32).write(to: file)
        XCTAssertEqual(try ClipDatabaseFile.readBounded(from: file, maximumBytes: 32).count, 32)
        XCTAssertThrowsError(try ClipDatabaseFile.readBounded(from: file, maximumBytes: 31))

        var buffer = BoundedResponseBuffer(maximumBytes: 32)
        XCTAssertNoThrow(try buffer.append(Data(repeating: 0x42, count: 32)))
        XCTAssertThrowsError(try buffer.append(Data([0x43]))) {
            XCTAssertEqual($0 as? BoundedResponseError, .responseTooLarge)
        }
        XCTAssertTrue(BoundedResponseBuffer.accepts(expectedContentLength: 32, maximumBytes: 32))
        XCTAssertFalse(BoundedResponseBuffer.accepts(expectedContentLength: 33, maximumBytes: 32))
    }
}

private actor WebsiteTitleHopRecorder {
    private var resolutions: [String] = []
    private var connections: [String] = []

    func recordResolution(_ host: String) {
        resolutions.append(host)
    }

    func recordConnection(numericAddress: String, originalHost: String) {
        connections.append("\(numericAddress)|\(originalHost)")
    }

    func snapshot() -> (resolutions: [String], connections: [String]) {
        (resolutions, connections)
    }
}
