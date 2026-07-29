import SwiftUI
import UIKit

struct HistoryView: View {
    @EnvironmentObject private var app: ClipmanAppModel
    @State private var viewingEntry: ClipEntry?
    @State private var editingEntry: ClipEntry?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                VStack(spacing: 8) {
                    controls
                    TabView(selection: selectedSectionBinding) {
                        ForEach(app.visibleSections) { section in
                            entryList(for: section)
                                .tag(section)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    statusBar(proxy: proxy)
                }
            }
            .navigationTitle("Clipman")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    PasteButton(payloadType: MobileClipboardPayload.self) { values in
                        app.addPastedClipboardPayload(values.first)
                    }
                        .accessibilityHint("Adds the current iOS clipboard text and available formatting to Clipman.")
                    Button("Switch to \(app.nextSection.rawValue)") {
                        app.switchSection(app.nextSection)
                    }
                    .disabled(app.visibleSections.count < 2)
                    .accessibilityLabel("Switch to \(app.nextSection.rawValue)")
                    Button("Settings") { app.showingSettings = true }
                }
            }
            .refreshable {
                await app.refresh(showStatus: true)
            }
            .accessibilityAction(.magicTap) {
                app.requestClipboardImport()
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

    private var selectedSectionBinding: Binding<ClipmanAppModel.Section> {
        Binding(
            get: { app.selectedSection },
            set: { app.switchSection($0) }
        )
    }

    private func entryList(for section: ClipmanAppModel.Section) -> some View {
        List {
            if section == .links {
                if app.visibleLinkItems(in: section).isEmpty {
                    Text("No links.")
                        .foregroundStyle(.secondary)
                }
                ForEach(app.visibleLinkItems(in: section)) { item in
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
                if app.visibleEntries(in: section).isEmpty {
                    Text("No entries.")
                        .foregroundStyle(.secondary)
                }
                ForEach(app.visibleEntries(in: section)) { entry in
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

    private var currentListIsEmpty: Bool {
        app.selectedSection == .links
            ? app.visibleLinkItems(in: app.selectedSection).isEmpty
            : app.visibleEntries(in: app.selectedSection).isEmpty
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

    private func statusBar(proxy: ScrollViewProxy) -> some View {
        Button {
            scrollToBottom(proxy: proxy)
        } label: {
            Text(app.status)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.bottom, 4)
        }
        .buttonStyle(.plain)
        .disabled(currentListIsEmpty)
        .accessibilityHint("Moves to the bottom of the current history list.")
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
            SourceMachine.isEmpty ? nil : "Device: \(SourceMachine)"
        ]
        .compactMap { $0 }
        .joined(separator: "; ")
    }

    var accessibilityLabelText: String {
        [
            Pinned ? "Pinned" : nil,
            displayText,
            Group.isEmpty ? nil : "Group: \(Group)",
            SourceMachine.isEmpty ? nil : "Device: \(SourceMachine)"
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
            entry.SourceMachine.isEmpty ? nil : "Device: \(entry.SourceMachine)"
        ]
        .compactMap { $0 }
        .joined(separator: "; ")
    }
}
