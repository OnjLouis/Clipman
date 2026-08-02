import SwiftUI
import UIKit

struct EntryView: View {
    let entry: ClipEntry
    @Environment(\.dismiss) private var dismiss

    private var links: [URL] {
        LinkExtractor.links(in: entry.Text)
    }

    private var embeddedImage: EmbeddedImage? {
        EmbeddedImageCodec.recognize(entry.RichText)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Clipboard text") {
                    ForEach(lines, id: \.self) { line in
                        Text(line)
                            .textSelection(.enabled)
                    }
                }
                if let embeddedImage, let image = UIImage(data: embeddedImage.data) {
                    Section("Image preview") {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(embeddedImage.altText)
                    }
                }
                if !links.isEmpty {
                    Section("Links") {
                        ForEach(Array(links.enumerated()), id: \.offset) { _, url in
                            Button(url.absoluteString) {
                                UIApplication.shared.open(url)
                            }
                            .accessibilityLabel(url.absoluteString)
                        }
                    }
                }
                Section("Details") {
                    ForEach(metadataLines, id: \.self) { line in
                        Text(line)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("View Entry")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
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
