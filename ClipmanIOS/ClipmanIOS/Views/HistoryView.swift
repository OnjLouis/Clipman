import SwiftUI
import UIKit

struct HistoryView: View {
    @EnvironmentObject private var app: ClipmanAppModel
    @State private var viewingEntry: ClipEntry?
    @State private var editingEntry: ClipEntry?
    @State private var pendingDeleteEntry: ClipEntry?
    @State private var pendingWebsiteTitleItem: LinkExtractor.LinkItem?
    @State private var imageShareFile: EmbeddedImageShareFile?
    @State private var showingHistoryFilter = false
    @AccessibilityFocusState private var focusedHistoryItemID: String?

    private let statusFocusID = "history-status"

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
            .sheet(item: $imageShareFile) { file in
                EmbeddedImageShareSheet(file: file) { completed, error in
                    Task { @MainActor in
                        imageShareFile = nil
                        if let error {
                            app.setTransientStatus("Image could not be shared: \(error.localizedDescription)")
                        } else if completed {
                            app.setTransientStatus("Image shared.")
                        } else {
                            app.setTransientStatus("Sharing cancelled.")
                        }
                    }
                }
                .onDisappear { file.remove() }
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
                    performDelete(entry)
                }
            } message: {
                Text("This removes the entry from synchronized history.")
            }
            .confirmationDialog("Use Website Title as Name?", isPresented: Binding(
                get: { pendingWebsiteTitleItem != nil },
                set: { if !$0 { pendingWebsiteTitleItem = nil } }
            ), titleVisibility: .visible) {
                Button("Cancel", role: .cancel) { pendingWebsiteTitleItem = nil }
                Button("Use Website Title") {
                    guard let item = pendingWebsiteTitleItem else { return }
                    pendingWebsiteTitleItem = nil
                    Task { await app.useWebsiteTitleAsName(entryID: item.entry.Id, url: item.url) }
                }
            } message: {
                Text("Clipman will contact \(pendingWebsiteTitleItem?.url.host ?? "the website") once to read the page title. The website can see that it was contacted. Clipman sends the selected link request, but no cookies, credentials or other clipboard content.")
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
                        edit: { editingEntry = item.entry },
                        togglePinned: { app.togglePinned(item.entry) },
                        delete: { requestDelete(item.entry) },
                        useWebsiteTitle: { pendingWebsiteTitleItem = item }
                    )
                    .id(item.id)
                    .accessibilityFocused($focusedHistoryItemID, equals: linkFocusID(item.id))
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
                        delete: { requestDelete(entry) },
                        saveImageToPhotos: saveImageToPhotos,
                        shareImage: shareImage,
                        useWebsiteTitle: { url in
                            pendingWebsiteTitleItem = LinkExtractor.LinkItem(
                                id: "\(entry.Id)-website-title",
                                url: url,
                                entry: entry
                            )
                        }
                    )
                    .id(entry.Id)
                    .accessibilityFocused($focusedHistoryItemID, equals: entryFocusID(entry.Id))
                }
            }
        }
        .listStyle(.plain)
    }

    private func requestDelete(_ entry: ClipEntry) {
        if app.settings.confirmDeletions {
            pendingDeleteEntry = entry
        } else {
            performDelete(entry)
        }
    }

    private func saveImageToPhotos(_ image: EmbeddedImage) {
        Task { @MainActor in
            app.setTransientStatus("Saving image to Photos.")
            do {
                try await EmbeddedImagePhotoLibrary.save(image)
                app.setTransientStatus("Image saved to Photos.")
            } catch {
                app.setTransientStatus("Image could not be saved to Photos: \(error.localizedDescription)")
            }
        }
    }

    private func shareImage(_ image: EmbeddedImage) {
        do {
            imageShareFile = try EmbeddedImageShareFile.create(for: image)
        } catch {
            app.setTransientStatus("Image could not be shared: \(error.localizedDescription)")
        }
    }

    private func performDelete(_ entry: ClipEntry) {
        let nextFocusID = focusTarget(afterDeleting: entry)
        guard app.delete(entry) != nil else { return }
        Task { @MainActor in
            await Task.yield()
            focusedHistoryItemID = nextFocusID ?? statusFocusID
        }
    }

    private func focusTarget(afterDeleting entry: ClipEntry) -> String? {
        if app.selectedSection == .links {
            let items = app.visibleLinkItems(in: app.selectedSection)
            let removed = Set(items.filter { $0.entry.Id == entry.Id }.map(\.id))
            return HistoryDeletionFocusResolver.nextID(
                afterRemoving: removed,
                from: items.map(\.id)
            ).map(linkFocusID)
        }
        return HistoryDeletionFocusResolver.nextID(
            afterRemoving: [entry.Id],
            from: app.visibleEntries(in: app.selectedSection).map(\.Id)
        ).map(entryFocusID)
    }

    private func entryFocusID(_ entryID: String) -> String { "entry:\(entryID)" }
    private func linkFocusID(_ linkID: String) -> String { "link:\(linkID)" }

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
        .accessibilityHint("Moves to the bottom of the current history list.")
        .accessibilityValue("Sort: \(app.settings.historySortMode.label)")
        .highPriorityGesture(
            LongPressGesture(minimumDuration: 0.6)
                .onEnded { _ in app.advanceHistorySortMode() }
        )
        .historySortAccessibilityActions { mode in
            app.setHistorySortMode(mode)
        }
        .accessibilityFocused($focusedHistoryItemID, equals: statusFocusID)
    }
}

enum HistoryDeletionFocusResolver {
    static func nextID(afterRemoving removedIDs: Set<String>, from orderedIDs: [String]) -> String? {
        let removedIndices = orderedIDs.indices.filter { removedIDs.contains(orderedIDs[$0]) }
        guard let firstRemoved = removedIndices.first, let lastRemoved = removedIndices.last else {
            return nil
        }
        if lastRemoved + 1 < orderedIDs.count,
           let next = orderedIDs[(lastRemoved + 1)...].first(where: { !removedIDs.contains($0) }) {
            return next
        }
        if firstRemoved > 0 {
            return orderedIDs[..<firstRemoved].reversed().first(where: { !removedIDs.contains($0) })
        }
        return nil
    }
}

private struct HistoryEntryRow: View {
    let entry: ClipEntry
    let copy: () -> Void
    let view: () -> Void
    let edit: () -> Void
    let togglePinned: () -> Void
    let delete: () -> Void
    let saveImageToPhotos: (EmbeddedImage) -> Void
    let shareImage: (EmbeddedImage) -> Void
    let useWebsiteTitle: (URL) -> Void

    private var embeddedImage: EmbeddedImage? {
        EmbeddedImageCodec.recognize(entry.RichText)
    }

    private var singleLink: URL? {
        guard HistoryRowPreview.canInspectLinks(in: entry.Text) else { return nil }
        let links = LinkExtractor.links(in: entry.Text)
        return links.count == 1 ? links[0] : nil
    }

    private var websiteTitleURL: URL? {
        guard entry.Name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return LinkExtractor.exactHTTPURL(in: entry)
    }

    var body: some View {
        EntryRow(entry: entry)
            .contentShape(Rectangle())
            .onTapGesture(perform: copy)
            .swipeActions(edge: .trailing) {
                if let url = singleLink {
                    Button {
                        UIApplication.shared.open(url)
                    } label: {
                        Label("Open", systemImage: "safari")
                    }
                    .accessibilityLabel("Open link")
                }
                Button(action: view) {
                    Label("View", systemImage: "doc.text.magnifyingglass")
                }
                .accessibilityLabel("View entry")
                Button(action: edit) {
                    Label("Edit", systemImage: "pencil")
                }
                .accessibilityLabel("Edit entry")
                Button(action: togglePinned) {
                    Label(entry.Pinned ? "Unpin" : "Pin", systemImage: entry.Pinned ? "pin.slash" : "pin")
                }
                .accessibilityLabel(entry.Pinned ? "Unpin entry" : "Pin entry")
                Button(role: .destructive, action: delete) {
                    Label("Delete", systemImage: "trash")
                }
                .accessibilityLabel("Delete entry")
                if let embeddedImage {
                    ForEach(EmbeddedImageHistoryActionPolicy.actions(for: embeddedImage), id: \.self) { action in
                        Button {
                            performImageAction(action, image: embeddedImage)
                        } label: {
                            Label(action.label, systemImage: action.systemImage)
                        }
                        .accessibilityLabel(action.label)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.accessibilityLabelText)
            .accessibilityHint("Double tap to copy to clipboard.")
            .accessibilityAddTraits(.isButton)
            .websiteTitleAccessibilityAction(enabled: websiteTitleURL != nil) {
                if let websiteTitleURL { useWebsiteTitle(websiteTitleURL) }
            }
            .contextMenu {
                Button("Copy", action: copy)
                if let url = singleLink {
                    Button("Open Link") { UIApplication.shared.open(url) }
                }
                Button("View", action: view)
                Button("Edit", action: edit)
                if let websiteTitleURL {
                    Button("Use Website Title as Name") { useWebsiteTitle(websiteTitleURL) }
                }
                Button(entry.Pinned ? "Unpin" : "Pin", action: togglePinned)
                Button("Delete", role: .destructive, action: delete)
                if let embeddedImage {
                    ForEach(EmbeddedImageHistoryActionPolicy.actions(for: embeddedImage), id: \.self) { action in
                        Button(action.label) { performImageAction(action, image: embeddedImage) }
                    }
                }
            }
    }

    private func performImageAction(_ action: EmbeddedImageHistoryAction, image: EmbeddedImage) {
        switch action {
        case .saveToPhotos:
            saveImageToPhotos(image)
        case .share:
            shareImage(image)
        }
    }
}

private struct LinkHistoryRow: View {
    let item: LinkExtractor.LinkItem
    let copy: () -> Void
    let open: () -> Void
    let view: () -> Void
    let edit: () -> Void
    let togglePinned: () -> Void
    let delete: () -> Void
    let useWebsiteTitle: () -> Void

    private var canUseWebsiteTitle: Bool {
        return item.entry.Name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && LinkExtractor.isExactWebsiteTitleTarget(item.entry, matching: item.url)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.displayText)
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
            Button(action: open) {
                Label("Open", systemImage: "safari")
            }
            .accessibilityLabel("Open link")
            Button(action: view) {
                Label("View", systemImage: "doc.text.magnifyingglass")
            }
            .accessibilityLabel("View entry")
            Button(action: edit) {
                Label("Edit", systemImage: "pencil")
            }
            .accessibilityLabel("Edit entry")
            Button(action: togglePinned) {
                Label(item.entry.Pinned ? "Unpin" : "Pin", systemImage: item.entry.Pinned ? "pin.slash" : "pin")
            }
            .accessibilityLabel(item.entry.Pinned ? "Unpin entry" : "Pin entry")
            Button(role: .destructive, action: delete) {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityLabel("Delete entry")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabelText)
        .accessibilityHint("Double tap to copy link to clipboard.")
        .accessibilityAddTraits(.isButton)
        .websiteTitleAccessibilityAction(enabled: canUseWebsiteTitle, action: useWebsiteTitle)
        .contextMenu {
            Button("Copy Link", action: copy)
            Button("Open Link", action: open)
            Button("View", action: view)
            Button("Edit", action: edit)
            if canUseWebsiteTitle {
                Button("Use Website Title as Name", action: useWebsiteTitle)
            }
            Button(item.entry.Pinned ? "Unpin" : "Pin", action: togglePinned)
            Button("Delete", role: .destructive, action: delete)
        }
    }
}

private extension View {
    @ViewBuilder
    func websiteTitleAccessibilityAction(enabled: Bool, action: @escaping () -> Void) -> some View {
        if enabled {
            accessibilityAction(named: "Use Website Title as Name", action)
        } else {
            self
        }
    }

    func historySortAccessibilityActions(
        setSort: @escaping (HistorySortMode) -> Void
    ) -> some View {
        accessibilityAction(named: HistorySortAccessibilityOrder.sourceModifierModes[0].accessibilityActionLabel) {
            setSort(HistorySortAccessibilityOrder.sourceModifierModes[0])
        }
        .accessibilityAction(named: HistorySortAccessibilityOrder.sourceModifierModes[1].accessibilityActionLabel) {
            setSort(HistorySortAccessibilityOrder.sourceModifierModes[1])
        }
        .accessibilityAction(named: HistorySortAccessibilityOrder.sourceModifierModes[2].accessibilityActionLabel) {
            setSort(HistorySortAccessibilityOrder.sourceModifierModes[2])
        }
        .accessibilityAction(named: HistorySortAccessibilityOrder.sourceModifierModes[3].accessibilityActionLabel) {
            setSort(HistorySortAccessibilityOrder.sourceModifierModes[3])
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

extension ClipEntry {
    var historyPreview: HistoryRowPreview.Value {
        let name = HistoryRowPreview.metadata(Name)
        if let image = EmbeddedImageCodec.recognize(RichText) {
            return HistoryRowPreview.make(
                name.isEmpty ? EmbeddedImageCodec.displayText(filename: image.filename) : name,
                sourceWasTruncated: HistoryRowPreview.exceedsMetadataLimit(Name)
            )
        }
        if let url = LinkExtractor.exactHTTPURL(in: self) {
            return HistoryRowPreview.make(
                LinkDisplay.rowText(for: url, name: name),
                sourceWasTruncated: HistoryRowPreview.exceedsMetadataLimit(Name)
            )
        }
        if !name.isEmpty {
            return HistoryRowPreview.joined(
                name: name,
                nameWasTruncated: HistoryRowPreview.exceedsMetadataLimit(Name),
                text: Text
            )
        }
        return HistoryRowPreview.make(Text)
    }

    var displayText: String {
        historyPreview.text
    }

    var detailText: String {
        [
            Group.isEmpty ? nil : "Group: \(HistoryRowPreview.metadata(Group))",
            SourceMachine.isEmpty ? nil : "Device: \(HistoryRowPreview.metadata(SourceMachine))"
        ]
        .compactMap { $0 }
        .joined(separator: "; ")
    }

    var accessibilityLabelText: String {
        [
            Pinned ? "Pinned" : nil,
            displayText,
            historyPreview.wasTruncated ? "Preview truncated" : nil,
            Group.isEmpty ? nil : "Group: \(HistoryRowPreview.metadata(Group))",
            SourceMachine.isEmpty ? nil : "Device: \(HistoryRowPreview.metadata(SourceMachine))"
        ]
        .compactMap { $0 }
        .joined(separator: "; ")
    }
}

private extension LinkExtractor.LinkItem {
    var displayText: String {
        HistoryRowPreview.make(
            LinkDisplay.rowText(for: url, name: HistoryRowPreview.metadata(entry.Name)),
            sourceWasTruncated: HistoryRowPreview.exceedsMetadataLimit(entry.Name)
        ).text
    }

    var accessibilityLabelText: String {
        [
            entry.Pinned ? "Pinned" : nil,
            displayText,
            HistoryRowPreview.exceedsMetadataLimit(entry.Name) ? "Preview truncated" : nil,
            entry.Group.isEmpty ? nil : "Group: \(HistoryRowPreview.metadata(entry.Group))",
            entry.SourceMachine.isEmpty ? nil : "Device: \(HistoryRowPreview.metadata(entry.SourceMachine))"
        ]
        .compactMap { $0 }
        .joined(separator: "; ")
    }
}

enum HistoryRowPreview {
    static let maximumScalars = 240
    static let maximumMetadataScalars = 80
    static let maximumLinkInspectionScalars = 16_384

    struct Value: Equatable {
        let text: String
        let wasTruncated: Bool
    }

    static func make(_ value: String, sourceWasTruncated: Bool = false) -> Value {
        clipped(value, maximumScalars: maximumScalars, sourceWasTruncated: sourceWasTruncated)
    }

    static func joined(name: String, nameWasTruncated: Bool, text: String) -> Value {
        let availableTextScalars = max(0, maximumScalars - name.unicodeScalars.count - 2)
        let textPreview = clipped(text, maximumScalars: availableTextScalars)
        return Value(
            text: name + ": " + textPreview.text,
            wasTruncated: nameWasTruncated || textPreview.wasTruncated
        )
    }

    static func metadata(_ value: String) -> String {
        LinkPresentationSafety.cleanedText(value, maximumScalars: maximumMetadataScalars)
    }

    static func exceedsMetadataLimit(_ value: String) -> Bool {
        value.unicodeScalars.prefix(maximumMetadataScalars + 1).count > maximumMetadataScalars
    }

    static func canInspectLinks(in value: String) -> Bool {
        value.unicodeScalars.prefix(maximumLinkInspectionScalars + 1).count <= maximumLinkInspectionScalars
    }

    private static func clipped(
        _ value: String,
        maximumScalars: Int,
        sourceWasTruncated: Bool = false
    ) -> Value {
        let safeMaximum = max(0, maximumScalars)
        let prefix = value.unicodeScalars.prefix(safeMaximum + 1)
        let truncated = sourceWasTruncated || prefix.count > safeMaximum
        let visibleScalars = prefix.prefix(safeMaximum)
        return Value(
            text: String(visibleScalars) + (truncated ? "..." : ""),
            wasTruncated: truncated
        )
    }
}
