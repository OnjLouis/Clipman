import SwiftUI
import UIKit

struct HistoryView: View {
    @EnvironmentObject private var app: ClipmanAppModel
    @State private var viewingEntry: ClipEntry?
    @State private var editingEntry: ClipEntry?
    @State private var pendingDeleteEntry: ClipEntry?
    @State private var showingHistoryFilter = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                VStack(spacing: 8) {
                    controls
                    TabView(selection: selectedSectionBinding) {
                        ForEach(app.visibleSections) { section in
                            entryList(for: section)
                                .tag(section)
                                .accessibilityLabel("\(section.rawValue) clipboard history")
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
            .sheet(isPresented: $showingHistoryFilter) {
                HistoryFilterChooser()
                    .environmentObject(app)
            }
            .alert("Delete clipboard entry?", isPresented: Binding(
                get: { pendingDeleteEntry != nil },
                set: { if !$0 { pendingDeleteEntry = nil } }
            )) {
                Button("Cancel", role: .cancel) { pendingDeleteEntry = nil }
                Button("Delete", role: .destructive) {
                    guard let entry = pendingDeleteEntry else { return }
                    pendingDeleteEntry = nil
                    app.delete(entry)
                }
            } message: {
                Text("This removes the entry from synchronized history.")
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                Button("Filter: \(app.historyFilter.value.isEmpty ? "All" : app.historyFilter.value)") {
                    showingHistoryFilter = true
                }
                .accessibilityHint("Shows groups and devices.")

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
                        delete: { requestDelete(item.entry) }
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
                        delete: { requestDelete(entry) }
                    )
                    .id(entry.Id)
                }
            }
        }
        .listStyle(.plain)
    }

    private func requestDelete(_ entry: ClipEntry) {
        if app.settings.confirmDeletions {
            pendingDeleteEntry = entry
        } else {
            app.delete(entry)
        }
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

    private var singleLink: URL? {
        let links = LinkExtractor.links(in: entry.Text)
        return links.count == 1 ? links[0] : nil
    }

    var body: some View {
        EntryRow(entry: entry)
            .contentShape(Rectangle())
            .onTapGesture(perform: copy)
            .swipeActions(edge: .trailing) {
                Button(role: .destructive, action: delete) {
                    Label("Delete", systemImage: "trash")
                }
                .accessibilityLabel("Delete entry")
                Button(action: togglePinned) {
                    Label(entry.Pinned ? "Unpin" : "Pin", systemImage: entry.Pinned ? "pin.slash" : "pin")
                }
                .accessibilityLabel(entry.Pinned ? "Unpin entry" : "Pin entry")
                Button(action: edit) {
                    Label("Edit", systemImage: "pencil")
                }
                .accessibilityLabel("Edit entry")
                Button(action: view) {
                    Label("View", systemImage: "doc.text.magnifyingglass")
                }
                .accessibilityLabel("View entry")
                if let url = singleLink {
                    Button {
                        UIApplication.shared.open(url)
                    } label: {
                        Label("Open", systemImage: "safari")
                    }
                    .accessibilityLabel("Open link")
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
                if let url = singleLink {
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

private struct HistoryFilterChooser: View {
    @EnvironmentObject private var app: ClipmanAppModel
    @Environment(\.dismiss) private var dismiss
    @AccessibilityFocusState private var focusedFilterID: String?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    filterButton(.all)
                    if !app.groups.isEmpty {
                        Section("Groups") {
                            ForEach(app.groups, id: \.self) { group in
                                filterButton(.init(kind: .group, value: group))
                            }
                        }
                    }
                    if !app.devices.isEmpty {
                        Section("Devices") {
                            ForEach(app.devices, id: \.self) { device in
                                filterButton(.init(kind: .device, value: device))
                            }
                        }
                    }
                }
                .navigationTitle("History Filter")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .onAppear {
                    let selectedID = normalizedCurrentFilter.id
                    DispatchQueue.main.async {
                        proxy.scrollTo(selectedID, anchor: .center)
                        focusedFilterID = selectedID
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func filterButton(_ filter: ClipmanAppModel.HistoryFilter) -> some View {
        Button {
            app.historyFilter = filter
            dismiss()
        } label: {
            HStack {
                Text(filter.value.isEmpty ? "All" : filter.value)
                Spacer()
                if isSelected(filter) {
                    Image(systemName: "checkmark")
                }
            }
        }
        .id(filter.id)
        .accessibilityValue(isSelected(filter) ? "Selected" : "")
        .accessibilityFocused($focusedFilterID, equals: filter.id)
    }

    private var normalizedCurrentFilter: ClipmanAppModel.HistoryFilter {
        switch app.historyFilter.kind {
        case .all:
            return .all
        case .group:
            let value = app.groups.first { $0.caseInsensitiveCompare(app.historyFilter.value) == .orderedSame }
            return value.map { .init(kind: .group, value: $0) } ?? .all
        case .device:
            let value = app.devices.first { $0.caseInsensitiveCompare(app.historyFilter.value) == .orderedSame }
            return value.map { .init(kind: .device, value: $0) } ?? .all
        }
    }

    private func isSelected(_ filter: ClipmanAppModel.HistoryFilter) -> Bool {
        filter.kind == app.historyFilter.kind &&
            filter.value.caseInsensitiveCompare(app.historyFilter.value) == .orderedSame
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
