import SwiftUI
import UIKit

struct HistoryView: View {
    @EnvironmentObject private var app: ClipmanAppModel
    @State private var viewingEntry: ClipEntry?
    @State private var editingEntry: ClipEntry?

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                controls
                entryList
                statusBar
            }
            .navigationTitle("Clipman")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Paste") { app.addCurrentClipboard() }
                        .accessibilityHint("Adds the current iOS clipboard text to Clipman.")
                    Button(app.selectedSection == .text ? "Switch to Links" : "Switch to Text") {
                        app.selectedSection = app.selectedSection == .text ? .links : .text
                    }
                    .disabled(!app.settings.linksEnabled)
                    .accessibilityLabel(app.selectedSection == .text ? "Switch to Links" : "Switch to Text")
                    Button("Settings") { app.showingSettings = true }
                }
            }
            .refreshable {
                await app.refresh(showStatus: true)
            }
            .accessibilityAction(.magicTap) {
                app.addCurrentClipboard()
            }
            .accessibilityScrollAction { edge in
                switch edge {
                case .leading:
                    app.switchSection(.links)
                case .trailing:
                    app.switchSection(.text)
                default:
                    break
                }
            }
            .onChange(of: app.status) { newStatus in
                app.announceStatus(newStatus)
            }
            .sheet(item: $viewingEntry) { entry in
                EntryView(entry: entry)
            }
            .sheet(item: $editingEntry) { entry in
                EntryEditView(entry: entry)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Group", selection: $app.groupFilter) {
                    ForEach(app.groups, id: \.self) { group in
                        Text(group).tag(group)
                    }
                }
                .pickerStyle(.menu)

                Spacer()

                if app.isRefreshing {
                    ProgressView()
                        .accessibilityLabel("Refreshing")
                }
            }
            .font(.callout)

            TextField("Search", text: $app.searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search history")
        }
        .padding(.horizontal)
    }

    private var entryList: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack {
                    Button("Top") {
                        scrollToTop(proxy: proxy)
                    }
                    .disabled(currentListIsEmpty)

                    Spacer()

                    Button("Bottom") {
                        scrollToBottom(proxy: proxy)
                    }
                    .disabled(currentListIsEmpty)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)

                List {
                    if app.selectedSection == .links {
                        if app.visibleLinkItems.isEmpty {
                            Text("No links.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(app.visibleLinkItems) { item in
                            LinkHistoryRow(
                                item: item,
                                copy: { app.copyText(item.url.absoluteString) },
                                open: { UIApplication.shared.open(item.url) },
                                view: { viewingEntry = item.entry },
                                delete: { app.delete(item.entry) }
                            )
                            .id(item.id)
                        }
                    } else {
                        if app.visibleEntries.isEmpty {
                            Text("No entries.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(app.visibleEntries) { entry in
                            HistoryEntryRow(
                                entry: entry,
                                copy: { app.copy(entry) },
                                view: { viewingEntry = entry },
                                edit: { editingEntry = entry },
                                togglePinned: { app.togglePinned(entry) },
                                delete: { app.delete(entry) }
                            )
                            .id(entry.Id)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var currentListIsEmpty: Bool {
        app.selectedSection == .links ? app.visibleLinkItems.isEmpty : app.visibleEntries.isEmpty
    }

    private func scrollToTop(proxy: ScrollViewProxy) {
        if app.selectedSection == .links, let first = app.visibleLinkItems.first {
            proxy.scrollTo(first.id, anchor: .top)
            UIAccessibility.post(notification: .layoutChanged, argument: first.accessibilityLabelText)
        } else if let first = app.visibleEntries.first {
            proxy.scrollTo(first.Id, anchor: .top)
            UIAccessibility.post(notification: .layoutChanged, argument: first.accessibilityLabelText)
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if app.selectedSection == .links, let last = app.visibleLinkItems.last {
            proxy.scrollTo(last.id, anchor: .bottom)
            UIAccessibility.post(notification: .layoutChanged, argument: last.accessibilityLabelText)
        } else if let last = app.visibleEntries.last {
            proxy.scrollTo(last.Id, anchor: .bottom)
            UIAccessibility.post(notification: .layoutChanged, argument: last.accessibilityLabelText)
        }
    }

    private var availableSections: [ClipmanAppModel.Section] {
        app.settings.linksEnabled ? ClipmanAppModel.Section.allCases : [.text]
    }

    private var statusBar: some View {
        Text(app.status)
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.bottom, 4)
    }
}

private struct HistoryEntryRow: View {
    let entry: ClipEntry
    let copy: () -> Void
    let view: () -> Void
    let edit: () -> Void
    let togglePinned: () -> Void
    let delete: () -> Void

    var body: some View {
        EntryRow(entry: entry)
            .contentShape(Rectangle())
            .onTapGesture(perform: copy)
            .swipeActions(edge: .trailing) {
                Button(role: .destructive, action: delete) {
                    Label("Delete", systemImage: "trash")
                }
                Button(action: view) {
                    Label("View", systemImage: "doc.text.magnifyingglass")
                }
            }
            .swipeActions(edge: .leading) {
                Button(action: togglePinned) {
                    Label(entry.Pinned ? "Unpin" : "Pin", systemImage: entry.Pinned ? "pin.slash" : "pin")
                }
                Button(action: edit) {
                    Label("Edit", systemImage: "pencil")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.accessibilityLabelText)
            .accessibilityHint("Double tap to copy to clipboard.")
            .accessibilityAddTraits(.isButton)
            .contextMenu {
                Button("Copy", action: copy)
                Button("View", action: view)
                Button("Edit", action: edit)
                Button(entry.Pinned ? "Unpin" : "Pin", action: togglePinned)
                Button("Delete", role: .destructive, action: delete)
                if LinkExtractor.links(in: entry.Text).count == 1, let url = LinkExtractor.links(in: entry.Text).first {
                    Button("Open Link") { UIApplication.shared.open(url) }
                }
            }
    }
}

private struct LinkHistoryRow: View {
    let item: LinkExtractor.LinkItem
    let copy: () -> Void
    let open: () -> Void
    let view: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.url.absoluteString)
                .lineLimit(2)
            if !item.entry.Group.isEmpty || !item.entry.SourceMachine.isEmpty {
                Text(item.entry.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: copy)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: delete) {
                Label("Delete Source Entry", systemImage: "trash")
            }
            Button(action: view) {
                Label("View Source Entry", systemImage: "doc.text.magnifyingglass")
            }
        }
        .swipeActions(edge: .leading) {
            Button(action: open) {
                Label("Open", systemImage: "safari")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabelText)
        .accessibilityHint("Double tap to copy link to clipboard.")
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            Button("Copy Link", action: copy)
            Button("Open Link", action: open)
            Button("View Source Entry", action: view)
            Button("Delete Source Entry", role: .destructive, action: delete)
        }
    }
}

private struct EntryRow: View {
    let entry: ClipEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if entry.Pinned {
                    Text("Pinned")
                        .font(.caption)
                        .bold()
                }
                Text(entry.displayText)
                    .lineLimit(2)
            }
            if !entry.Group.isEmpty || !entry.SourceMachine.isEmpty {
                Text(entry.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

private extension ClipEntry {
    var displayText: String {
        if !Name.isEmpty {
            return "\(Name): \(Text)"
        }
        return Text
    }

    var detailText: String {
        [
            Group.isEmpty ? nil : "Group: \(Group)",
            SourceMachine.isEmpty ? nil : "Machine: \(SourceMachine)"
        ]
        .compactMap { $0 }
        .joined(separator: "; ")
    }

    var accessibilityLabelText: String {
        [
            Pinned ? "Pinned" : nil,
            displayText,
            Group.isEmpty ? nil : "Group: \(Group)",
            SourceMachine.isEmpty ? nil : "Machine: \(SourceMachine)"
        ]
        .compactMap { $0 }
        .joined(separator: "; ")
    }
}

private extension LinkExtractor.LinkItem {
    var accessibilityLabelText: String {
        [
            url.absoluteString,
            entry.Group.isEmpty ? nil : "Group: \(entry.Group)",
            entry.SourceMachine.isEmpty ? nil : "Machine: \(entry.SourceMachine)"
        ]
        .compactMap { $0 }
        .joined(separator: "; ")
    }
}
