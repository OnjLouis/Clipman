import XCTest
import UIKit
@testable import Clipman

final class HistoryPresentationCacheTests: XCTestCase {
    @MainActor
    func testFocusAndStatusChangesReusePresentationWithoutResortingHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = model(root: root)
        app.database = ClipDatabase(Entries: fixture(count: 30))
        let text = app.visibleEntries(in: .text)
        let links = app.visibleLinkItems(in: .links)
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(links.isEmpty)

        for index in 0..<10 {
            app.readingState.historyFocusID = "entry:text-\(index)"
            app.status = "Status \(index)"
            app.isRefreshing.toggle()
            app.selectedSection = index.isMultiple(of: 2) ? .text : .links
            app.settings.deviceName = "Test device \(index)"
            assertSameStorage(text, app.visibleEntries(in: .text))
            assertSameStorage(links, app.visibleLinkItems(in: .links))
        }
    }

    @MainActor
    func testChangesToPresentationInputsInvalidateEveryAffectedSection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = model(root: root)
        app.database = ClipDatabase(Entries: [
            ClipEntry(Id: "a", Text: "Alpha", Group: "Work", SourceMachine: "PC", ManualOrder: 2),
            ClipEntry(Id: "b", Text: "Beta", Group: "Home", SourceMachine: "Phone", ManualOrder: 1),
            ClipEntry(Id: "link", Text: "https://example.com/old", Group: "Work"),
            ClipEntry(Id: "rich", Text: "Formatted", RichText: RichTextPayload(HtmlFragment: "<b>Formatted</b>"))
        ])
        XCTAssertEqual(app.visibleEntries(in: .text).map(\.Id), ["b", "a"])
        XCTAssertEqual(app.visibleLinkItems(in: .links).count, 1)
        XCTAssertEqual(app.visibleEntries(in: .richText).map(\.Id), ["rich"])

        app.searchText = "Alpha"
        XCTAssertEqual(app.visibleEntries(in: .text).map(\.Id), ["a"])
        XCTAssertTrue(app.visibleLinkItems(in: .links).isEmpty)
        app.searchText = ""
        XCTAssertEqual(app.visibleLinkItems(in: .links).count, 1)
        app.historyFilter = .init(kind: .device, value: "phone")
        XCTAssertEqual(app.visibleEntries(in: .text).map(\.Id), ["b"])
        app.historyFilter = .init(kind: .group, value: "WORK")
        XCTAssertEqual(app.visibleEntries(in: .text).map(\.Id), ["a"])
        XCTAssertEqual(app.visibleLinkItems(in: .links).count, 1)
        app.historyFilter = .all
        app.settings.historySortMode = .text
        XCTAssertEqual(app.visibleEntries(in: .text).map(\.Id), ["a", "b"])

        app.database.Entries[0].Text = "Zulu"
        XCTAssertEqual(app.visibleEntries(in: .text).map(\.Id), ["b", "a"])
        app.database.Entries[0].Pinned = true
        XCTAssertEqual(app.visibleEntries(in: .text).map(\.Id), ["a", "b"])
        app.database.Entries[2].Text = "https://example.com/new"
        XCTAssertEqual(app.visibleLinkItems(in: .links).first?.url.path, "/new")
        app.database.Entries.removeAll { $0.Id == "link" }
        XCTAssertTrue(app.visibleLinkItems(in: .links).isEmpty)

        app.settings.richTextEnabled = false
        XCTAssertTrue(app.visibleEntries(in: .richText).isEmpty)
        XCTAssertTrue(app.visibleEntries(in: .text).contains { $0.Id == "rich" })
        app.database.Entries.append(ClipEntry(Id: "new-link", Text: "https://example.com/another"))
        app.settings.linksEnabled = false
        XCTAssertTrue(app.visibleEntries(in: .text).contains { $0.Id == "new-link" })
        app.settings.linksEnabled = true
        XCTAssertFalse(app.visibleEntries(in: .text).contains { $0.Id == "new-link" })
        XCTAssertEqual(app.visibleLinkItems(in: .links).count, 1)
    }

    @MainActor
    func testRepeatedHistoryPresentationBenchmark() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = model(root: root)
        app.database = ClipDatabase(Entries: fixture(count: 1682))
        let start = CFAbsoluteTimeGetCurrent()
        var count = 0
        for _ in 0..<100 {
            for section in ClipmanAppModel.Section.allCases {
                for _ in 0..<3 {
                    count += section == .links
                        ? app.visibleLinkItems(in: section).count
                        : app.visibleEntries(in: section).count
                }
            }
        }
        XCTAssertEqual(count, 1682 * 300)
        print("HISTORY_PRESENTATION_BENCHMARK entries=1682 calls=900 seconds=\(CFAbsoluteTimeGetCurrent() - start)")
    }

    func testRepeatedImagePreviewBenchmark() throws {
        let side = 256
        var state: UInt32 = 12345
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for index in pixels.indices where index % 4 != 3 {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            pixels[index] = UInt8(truncatingIfNeeded: state)
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let data = try XCTUnwrap(UIImage(cgImage: image).pngData())
        let payload = try EmbeddedImageCodec.makePayload(data: data, suggestedFilename: "synthetic.png")
        let entry = ClipEntry(Id: "synthetic-image", Text: payload.text, RichText: payload.richText)
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<20 {
            XCTAssertEqual(entry.displayText, "Image: synthetic.png")
            XCTAssertEqual(entry.accessibilityLabelText, "Image: synthetic.png")
        }
        print("IMAGE_PREVIEW_BENCHMARK bytes=\(data.count) passes=20 seconds=\(CFAbsoluteTimeGetCurrent() - start)")
    }

    @MainActor
    private func model(root: URL) -> ClipmanAppModel {
        var settings = ClipmanSettings.empty
        settings.linksEnabled = true
        settings.richTextEnabled = true
        return ClipmanAppModel(
            settings: settings,
            quickClipDraftStore: ClipDraftStore(fileURL: root.appendingPathComponent("quick.json")),
            entryEditDraftStore: ClipDraftStore(fileURL: root.appendingPathComponent("edit.json")),
            readingStateStore: HistoryReadingStateStore(fileURL: root.appendingPathComponent("reading.json"))
        )
    }

    private func fixture(count: Int) -> [ClipEntry] {
        (0..<count).map { index in
            ClipEntry(
                Id: "entry-\(index)",
                Text: index.isMultiple(of: 4) ? "https://example.com/item/\(index)" : "Synthetic entry \(index)",
                Group: index.isMultiple(of: 2) ? "Work" : "Home",
                SourceMachine: "Test device",
                CreatedUnixMs: Int64(index),
                Pinned: index.isMultiple(of: 11),
                ManualOrder: Int64(count - index)
            )
        }
    }

    private func assertSameStorage<T>(_ first: [T], _ second: [T], file: StaticString = #filePath, line: UInt = #line) {
        first.withUnsafeBufferPointer { left in
            second.withUnsafeBufferPointer { right in
                XCTAssertEqual(left.baseAddress, right.baseAddress, "Unchanged presentations should reuse their array storage", file: file, line: line)
            }
        }
    }
}
