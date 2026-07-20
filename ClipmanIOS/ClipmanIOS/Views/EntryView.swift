import SwiftUI
import UIKit

struct EntryView: View {
    let entry: ClipEntry
    @Environment(\.dismiss) private var dismiss

    private var links: [URL] {
        LinkExtractor.links(in: entry.Text)
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
            lines.append("Machine: \(entry.SourceMachine)")
        }
        lines.append("Pinned: \(entry.Pinned ? "Yes" : "No")")
        lines.append("Template: \(entry.IsTemplate ? "Yes" : "No")")
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

    private func formatUnixMilliseconds(_ value: Int64) -> String {
        guard value > 0 else { return "Unknown" }
        let date = Date(timeIntervalSince1970: TimeInterval(value) / 1000)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}
