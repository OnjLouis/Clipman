import SwiftUI
import UIKit

struct EntryView: View {
    let entry: ClipEntry
    @EnvironmentObject private var app: ClipmanAppModel
    @State private var showingLargeImage = false
    @AccessibilityFocusState private var focusedRowID: String?
    private let readingSpace = "entry-viewer"

    private var links: [URL] {
        LinkExtractor.links(in: entry.Text)
    }

    private var embeddedImage: EmbeddedImage? {
        EmbeddedImageCodec.recognize(entry.RichText)
    }

    var body: some View {
        NavigationStack {
            RememberedList(
                coordinateSpace: readingSpace,
                rowIDs: readingRowIDs,
                savedAnchor: app.readingState.viewerAnchor,
                remember: { app.readingState.viewerAnchor = $0 },
                onRestore: restoreReadingFocus
            ) {
                Section("Clipboard text") {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .textSelection(.enabled)
                            .readingPositionRow("text-\(index)", in: readingSpace)
                            .accessibilityFocused($focusedRowID, equals: "text-\(index)")
                    }
                }
                if let embeddedImage, let image = UIImage(data: embeddedImage.data) {
                    Section("Image preview") {
                        Button {
                            showingLargeImage = true
                        } label: {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                        }
                        .accessibilityLabel("View larger image: \(embeddedImage.altText)")
                        .readingPositionRow("image", in: readingSpace)
                        .accessibilityFocused($focusedRowID, equals: "image")
                    }
                }
                if !links.isEmpty {
                    Section("Links") {
                        ForEach(Array(links.enumerated()), id: \.offset) { index, url in
                            Button(url.absoluteString) {
                                UIApplication.shared.open(url)
                            }
                            .accessibilityLabel(url.absoluteString)
                            .readingPositionRow("link-\(index)", in: readingSpace)
                            .accessibilityFocused($focusedRowID, equals: "link-\(index)")
                        }
                    }
                }
                Section("Details") {
                    ForEach(Array(metadataLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .textSelection(.enabled)
                            .readingPositionRow("detail-\(index)", in: readingSpace)
                            .accessibilityFocused($focusedRowID, equals: "detail-\(index)")
                    }
                }
            }
            .navigationTitle("View Entry")
            .task {
                showingLargeImage = app.readingState.showingLargeImage
            }
            .onChange(of: focusedRowID) { id in
                if let id { app.readingState.viewerFocusID = id }
            }
            .onChange(of: showingLargeImage) { value in
                if app.isUnlocked { app.readingState.showingLargeImage = value }
            }
            .accessibilityAction(.escape) { app.closeViewedEntry() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { app.closeViewedEntry() }
                }
            }
            .fullScreenCover(isPresented: $showingLargeImage) {
                if let embeddedImage, let image = UIImage(data: embeddedImage.data) {
                    NavigationStack {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityLabel(embeddedImage.altText)
                            .navigationTitle("Image preview")
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Close") { showingLargeImage = false }
                                }
                            }
                    }
                }
            }
        }
    }

    private func restoreReadingFocus() {
        guard let id = app.readingState.viewerFocusID, readingRowIDs.contains(id) else { return }
        Task { @MainActor in
            await Task.yield()
            if app.isUnlocked, app.showingEntryView, !showingLargeImage { focusedRowID = id }
        }
    }

    private var readingRowIDs: [String] {
        lines.indices.map { "text-\($0)" }
            + (embeddedImage == nil ? [] : ["image"])
            + links.indices.map { "link-\($0)" }
            + metadataLines.indices.map { "detail-\($0)" }
    }

    private var lines: [String] {
        let split = entry.Text.components(separatedBy: .newlines)
        return split.isEmpty ? [entry.Text] : split
    }

    private var metadataLines: [String] {
        var lines: [String] = []
        if !entry.Name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Name: \(entry.Name)")
        }
        if !entry.Group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Group: \(entry.Group)")
        }
        if !entry.SourceMachine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Device: \(entry.SourceMachine)")
        }
        lines.append("Pinned: \(entry.Pinned ? "Yes" : "No")")
        lines.append("Template: \(entry.IsTemplate ? "Yes" : "No")")
        lines.append("Formatting: \(formattingDescription)")
        if let image = embeddedImage {
            lines.append("Image filename: \(image.filename)")
            lines.append("Image type: \(image.typeDescription)")
            lines.append("Image dimensions: \(image.width) by \(image.height) pixels")
            lines.append("Stored image size: \(ByteCountFormatter.string(fromByteCount: Int64(image.data.count), countStyle: .file))")
            lines.append("Image metadata: \(image.containsMetadata ? "Present" : "Not present")")
        }
        lines.append("Added: \(formatUnixMilliseconds(entry.CreatedUnixMs))")
        lines.append("Last used: \(formatUnixMilliseconds(entry.LastUsedUnixMs))")
        if entry.ManualOrder > 0 {
            lines.append("Manual order: \(entry.ManualOrder)")
        }
        lines.append("Text length: \(entry.Text.count) characters")
        lines.append("Links: \(links.count)")
        if !entry.Id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Entry ID: \(entry.Id)")
        }
        return lines
    }

    private var formattingDescription: String {
        if let image = embeddedImage { return "Embedded \(image.typeDescription) image" }
        guard let payload = MobileRichTextClipboard.normalize(entry.RichText) else { return "Plain text" }
        var formats: [String] = []
        if !payload.HtmlFragment.isEmpty { formats.append("HTML") }
        if !payload.RtfBase64.isEmpty { formats.append("RTF") }
        return formats.isEmpty ? "Plain text" : formats.joined(separator: " and ")
    }

    private func formatUnixMilliseconds(_ value: Int64) -> String {
        guard value > 0 else { return "Unknown" }
        let date = Date(timeIntervalSince1970: TimeInterval(value) / 1000)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}
