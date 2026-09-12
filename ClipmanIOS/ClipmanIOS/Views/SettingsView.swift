import SwiftUI
import UniformTypeIdentifiers

private enum SettingsFileImport {
    case serverConnection
    case privateAuthority
    case historyBackup
}

struct SettingsView: View {
    @EnvironmentObject private var app: ClipmanAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ClipmanSettings.empty
    @State private var showServerConnection = false
    @State private var activeFileImport: SettingsFileImport?
    @State private var showFileImporter = false
    @State private var showConnectionExportWarning = false
    @State private var showConnectionExporter = false
    @State private var connectionDocument: ServerConnectionDocument?
    @State private var connectionShareFile: ServerConnectionShareFile?
    @State private var connectionShareFileForCleanup: ServerConnectionShareFile?
    @State private var pendingConnection: ServerConnectionDetails?
    @State private var pendingAuthority: ServerCertificateAuthority?
    @State private var connectionImportError = ""
    @State private var connectionExportError = ""
    @State private var showBackupFolderPicker = false
    @State private var showSharedFolderPicker = false
    @State private var backupError = ""
    @State private var backupMessage = ""
    @State private var settingsValidationError = ""
    @StateObject private var tipJar = TipJarStore()

    private var baseForm: some View {
        NavigationStack {
            Form {
                Section("History storage") {
                    Picker("Storage mode", selection: $draft.storageMode) {
                        ForEach(MobileStorageMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(storageModeDescription)
                        .font(.footnote)
                }

                if draft.storageMode == .sharedFolder {
                    sharedFolderSection
                }

                historyBackupSection

                Section("History display") {
                    Picker("Sort normal entries", selection: $draft.historySortMode) {
                        ForEach(HistorySortMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                }

                Section("Device") {
                    TextField("Device name", text: $draft.deviceName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    Toggle("Play sounds", isOn: $draft.soundsEnabled)
                    Toggle("Use haptics", isOn: $draft.hapticsEnabled)
                    Toggle("Enable links history", isOn: $draft.linksEnabled)
                    Toggle("Preserve copied formatting and show Rich Text history", isOn: $draft.richTextEnabled)
                        .onChange(of: draft.richTextEnabled) { enabled in
                            if !enabled { draft.includeImagesInRichText = false }
                        }
                    Toggle("Include images in Rich Text history", isOn: $draft.includeImagesInRichText)
                        .disabled(!draft.richTextEnabled)
                        .accessibilityHint("Off by default. Retained metadata can include camera or location information and follows your history encryption and sync choices.")
                    Text("Retained image metadata can include camera or location information. It follows the same encryption and sync choices as the rest of your history.")
                        .font(.footnote)
                    Toggle("Confirm before deleting entries", isOn: $draft.confirmDeletions)
                    Toggle("Copy latest remote item to iOS clipboard", isOn: $draft.autoCopyRemote)
                    Toggle("Add current clipboard on launch", isOn: $draft.addClipboardOnLaunch)
                    Toggle("Require biometric or device authentication", isOn: $draft.requireAuthentication)
                        .accessibilityHint("When enabled, Clipman asks for Face ID, Touch ID, or the device passcode whenever the app returns to the foreground.")
                }

                serverConnectionSection

                SyncRulesSettingsSection(app: app)

                TipJarSettingsSection(tipJar: tipJar)

                Section("Help") {
                    Link("Open Manual", destination: URL(string: "https://onjlouis.github.io/Clipman/manual.html")!)
                }

                Section("Build information") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Build", value: buildStamp)
                    LabeledContent("Built", value: formattedBuildTime)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        draft.serverURL = ServerSettingsSanitizer.cleanDisplayURL(draft.serverURL)
                        draft.serverToken = ServerSettingsSanitizer.cleanToken(draft.serverToken)
                        if !draft.serverCaCertPEM.isEmpty {
                            do {
                                guard let authority = try ServerSettingsSanitizer.parseCertificateAuthority(draft.serverCaCertPEM, address: draft.serverURL),
                                      draft.serverCaHost.isEmpty || authority.host.caseInsensitiveCompare(draft.serverCaHost) == .orderedSame
                                else { throw ConnectionConfigError.authorityHostMismatch }
                                draft.serverCaCertPEM = authority.pem
                                draft.serverCaHost = authority.host
                            } catch {
                                settingsValidationError = "The server host or connection scheme no longer matches the private certificate authority. Remove the authority or restore the matching HTTPS server address before saving."
                                showServerConnection = true
                                return
                            }
                        }
                        guard draft.storageMode != .server || !draft.historyPassword.isEmpty else {
                            settingsValidationError = "Clipman Server requires a unique history password. Enter one before saving this connection."
                            showServerConnection = true
                            return
                        }
                        guard draft.storageMode != .sharedFolder
                                || (!draft.historyPassword.isEmpty && !draft.sharedFolderBookmark.isEmpty) else {
                            settingsValidationError = "Shared folder sync requires a nonblank history password and a selected folder."
                            return
                        }
                        guard !draft.cloudBackupEnabled || (!draft.historyPassword.isEmpty && !draft.cloudBackupBookmark.isEmpty) else {
                            settingsValidationError = "Encrypted history backup requires a nonblank history password and a selected backup folder."
                            showServerConnection = true
                            return
                        }
                        app.saveSettings(draft)
                        dismiss()
                    }
                }
            }
        }
    }

    var body: some View {
        AnyView(baseForm)
            .onAppear {
                draft = app.settings
                showServerConnection = draft.storageMode == .server && !serverIsConfigured
                applyPendingConnectionImport()
            }
            .task {
                await tipJar.loadProducts()
            }
            .onChange(of: app.serverConnectionImportSequence) { _ in
                applyPendingConnectionImport()
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: allowedFileImportTypes,
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .sheet(isPresented: $showBackupFolderPicker) {
                BackupFolderPicker(
                    onSelect: { url in
                        showBackupFolderPicker = false
                        do {
                            draft.cloudBackupBookmark = try CloudHistoryBackup.bookmark(for: url)
                            draft.cloudBackupFolderName = url.lastPathComponent.isEmpty ? "Selected folder" : url.lastPathComponent
                            draft.cloudBackupEnabled = true
                            backupMessage = "Backup folder selected. Choose Save to apply it."
                        } catch {
                            backupError = error.localizedDescription
                        }
                    },
                    onCancel: { showBackupFolderPicker = false }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showSharedFolderPicker) {
                BackupFolderPicker(
                    onSelect: { url in
                        showSharedFolderPicker = false
                        do {
                            draft.sharedFolderBookmark = try CloudHistoryBackup.bookmark(for: url)
                            draft.sharedFolderName = url.lastPathComponent.isEmpty ? "Selected folder" : url.lastPathComponent
                        } catch {
                            backupError = error.localizedDescription
                        }
                    },
                    onCancel: { showSharedFolderPicker = false }
                )
                .ignoresSafeArea()
            }
            .fileExporter(
                isPresented: $showConnectionExporter,
                document: connectionDocument,
                contentType: .clipmanServerConnection,
                defaultFilename: "Clipman Server.clpconf"
            ) { result in
                if case .failure(let error) = result,
                   (error as NSError).code != NSUserCancelledError {
                    connectionExportError = error.localizedDescription
                }
                connectionDocument = nil
            }
            .sheet(item: $connectionShareFile, onDismiss: {
                connectionShareFileForCleanup?.remove()
                connectionShareFileForCleanup = nil
                connectionDocument = nil
            }) { file in
                ConnectionShareSheet(file: file)
            }
            .alert("Export private server connection?", isPresented: $showConnectionExportWarning) {
                Button("Cancel", role: .cancel) { connectionDocument = nil }
                Button("Save to Files") { showConnectionExporter = true }
                Button("Share") { shareConnectionDocument() }
            } message: {
                Text("This file contains the private server token. Store and share it securely, and never place it beside an exported clipboard history.")
            }
            .alert("Import Clipman Server connection?", isPresented: Binding(
                get: { pendingConnection != nil },
                set: { if !$0 { pendingConnection = nil } }
            )) {
                Button("Import") {
                    guard let details = pendingConnection else { return }
                    draft.storageMode = .server
                    draft.serverURL = details.address
                    draft.serverToken = details.token
                    if let authority = details.authority {
                        draft.serverCaCertPEM = authority.pem
                        draft.serverCaHost = authority.host
                    } else if (try? ServerSettingsSanitizer.parseCertificateAuthority(draft.serverCaCertPEM, address: details.address)) == nil {
                        draft.serverCaCertPEM = ""
                        draft.serverCaHost = ""
                    }
                    showServerConnection = true
                    pendingConnection = nil
                }
                Button("Cancel", role: .cancel) { pendingConnection = nil }
            } message: {
                Text("Server: \(pendingConnection?.address ?? "")\(authoritySummary(pendingConnection?.authority))\n\nThe token will remain hidden. Choose Save to apply this connection.")
            }
            .alert("Import private authority for this server?", isPresented: Binding(
                get: { pendingAuthority != nil },
                set: { if !$0 { pendingAuthority = nil } }
            )) {
                Button("Cancel", role: .cancel) { pendingAuthority = nil }
                Button("Import") {
                    guard let authority = pendingAuthority else { return }
                    draft.serverCaCertPEM = authority.pem
                    draft.serverCaHost = authority.host
                    pendingAuthority = nil
                }
            } message: {
                Text(authorityImportSummary(pendingAuthority))
            }
            .alert("Could not import server connection", isPresented: Binding(
                get: { !connectionImportError.isEmpty },
                set: { if !$0 { connectionImportError = "" } }
            )) {
                Button("OK") { connectionImportError = "" }
            } message: {
                Text(connectionImportError)
            }
            .alert("Could not export server connection", isPresented: Binding(
                get: { !connectionExportError.isEmpty },
                set: { if !$0 { connectionExportError = "" } }
            )) {
                Button("OK") { connectionExportError = "" }
            } message: {
                Text(connectionExportError)
            }
            .alert("History backup error", isPresented: Binding(
                get: { !backupError.isEmpty },
                set: { if !$0 { backupError = "" } }
            )) {
                Button("OK") { backupError = "" }
            } message: {
                Text(backupError)
            }
            .alert("History password required", isPresented: Binding(
                get: { !settingsValidationError.isEmpty },
                set: { if !$0 { settingsValidationError = "" } }
            )) {
                Button("OK") { settingsValidationError = "" }
            } message: {
                Text(settingsValidationError)
            }
        .accessibilityAction(.escape) {
            dismiss()
        }
    }

    private var serverIsConfigured: Bool {
        !draft.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var storageModeDescription: String {
        switch draft.storageMode {
        case .local:
            "History is stored privately on this iPhone. Server and shared-folder details remain saved for later."
        case .server:
            "History is cached on this iPhone and merged with Clipman Server. Offline changes retry automatically."
        case .sharedFolder:
            "History is cached on this iPhone and merged through an iCloud Drive or other shared folder. Clipman syncs while the app is open."
        }
    }

    private var sharedFolderSection: some View {
        Section("Shared folder sync") {
            SecureField("Shared history password", text: $draft.historyPassword)
                .accessibilityLabel("Shared history password")
                .accessibilityHint("Enter the same password used to encrypt this history on the other devices.")
            Text(draft.sharedFolderName.isEmpty
                ? "No shared folder selected."
                : "Shared folder: \(draft.sharedFolderName)")
                .font(.footnote)
            Button(draft.sharedFolderBookmark.isEmpty ? "Choose shared folder" : "Change shared folder") {
                showSharedFolderPicker = true
            }
            Text("Choose the same folder and history password on each device. Clipman merges encrypted entries, edits, pins, groups, and deletions; server credentials and settings are not shared.")
                .font(.footnote)
        }
    }

    private var historyBackupSection: some View {
        Section("Encrypted history backup") {
            Toggle("Back up encrypted history automatically", isOn: Binding(
                get: { draft.cloudBackupEnabled },
                set: { enabled in
                    if !enabled {
                        draft.cloudBackupEnabled = false
                    } else if draft.historyPassword.isEmpty {
                        settingsValidationError = "Set and save a nonblank history password before enabling encrypted history backup."
                        showServerConnection = true
                    } else if draft.cloudBackupBookmark.isEmpty {
                        showBackupFolderPicker = true
                    } else {
                        draft.cloudBackupEnabled = true
                    }
                }
            ))
            Text(draft.cloudBackupFolderName.isEmpty
                ? "No backup folder selected."
                : "Backup folder: \(draft.cloudBackupFolderName)")
                .font(.footnote)
            Button(draft.cloudBackupBookmark.isEmpty ? "Choose backup folder" : "Change backup folder") {
                showBackupFolderPicker = true
            }
            Button("Restore and merge history backup") {
                beginFileImport(.historyBackup)
            }
            Text("Clipman writes one encrypted history file after successful changes. Restoring merges entries and deletions; it does not replace newer history. Server details, tokens, settings, and passwords are never included.")
                .font(.footnote)
            if !backupMessage.isEmpty {
                Text(backupMessage)
                    .font(.footnote)
            }
        }
    }

    private var serverConnectionSection: some View {
        Section("Server connection") {
            Text(serverIsConfigured ? "Server connection is configured." : "Server connection needs setup.")
                .foregroundStyle(serverIsConfigured ? .secondary : .primary)
            Button(showServerConnection ? "Hide server connection" : "Show server connection") {
                showServerConnection.toggle()
            }
            Button("Import server connection file") {
                beginFileImport(.serverConnection)
            }
            .accessibilityHint("Choose a Clipman Server connection file, review its address, then save settings.")
            Button("Export server connection file") {
                do {
                    connectionDocument = ServerConnectionDocument(data: try ServerSettingsSanitizer.connectionConfigData(
                        address: draft.serverURL,
                        token: draft.serverToken,
                        caCertPEM: draft.serverCaCertPEM,
                        caHost: draft.serverCaHost
                    ))
                    showConnectionExportWarning = true
                } catch {
                    connectionExportError = error.localizedDescription
                }
            }
            .accessibilityHint("Save the current server address and private access token to a Clipman Server connection file.")
            Button("Import private authority") {
                beginFileImport(.privateAuthority)
            }
            .accessibilityHint("Choose a public certificate authority for the current HTTPS server host.")
            if !draft.serverCaCertPEM.isEmpty {
                Button("Remove private authority", role: .destructive) {
                    draft.serverCaCertPEM = ""
                    draft.serverCaHost = ""
                }
            }
            authorityStatus
            if showServerConnection {
                serverConnectionFields
            }
        }
    }

    @ViewBuilder
    private var authorityStatus: some View {
        if draft.serverCaCertPEM.isEmpty {
            Text("Private certificate authority: Not configured")
                .font(.footnote)
        } else if let authority = try? ServerSettingsSanitizer.parseCertificateAuthority(draft.serverCaCertPEM, address: draft.serverURL) {
            Text("Private certificate authority for \(authority.host). Subject: \(authority.subject). Expires: \(authority.expires.formatted(date: .long, time: .omitted)).")
                .font(.footnote)
            LabeledContent("Authority SHA-256 fingerprint", value: authority.fingerprint)
                .font(.footnote)
        } else {
            Text("Private certificate authority does not match the current server address.")
                .font(.footnote)
        }
    }

    private func authoritySummary(_ authority: ServerCertificateAuthority?) -> String {
        guard let authority else { return "" }
        return "\n\nPrivate authority host: \(authority.host)\nSubject: \(authority.subject)\nExpires: \(authority.expires.formatted(date: .long, time: .omitted))\nSHA-256 fingerprint: \(authority.fingerprint)"
    }

    private func authorityImportSummary(_ authority: ServerCertificateAuthority?) -> String {
        guard let authority else { return "" }
        return "Host: \(authority.host)\nSubject: \(authority.subject)\nExpires: \(authority.expires.formatted(date: .long, time: .omitted))\nSHA-256 fingerprint: \(authority.fingerprint)\n\nClipman will trust this authority only for the displayed server host."
    }

    private var serverConnectionFields: some View {
        Group {
            TextField("Server address", text: $draft.serverURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Server address")
                .accessibilityHint("Enter the Clipman Server address and port.")
            SecureField("Server token", text: $draft.serverToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(draft.storageMode == .local)
                .accessibilityLabel("Server token")
                .accessibilityHint("Enter the access token supplied by Clipman Server.")
            SecureField("History password", text: $draft.historyPassword)
                .accessibilityLabel("History password")
                .accessibilityHint("Enter the password used to encrypt this clipboard history.")
            Text("You can paste a full token line or a clipman:// server address; Clipman will clean it when saving.")
                .font(.footnote)
        }
    }

    private func applyPendingConnectionImport() {
        let (details, errorMessage) = app.consumeServerConnectionImport()
        if let details {
            pendingConnection = details
        } else if !errorMessage.isEmpty {
            connectionImportError = errorMessage
        }
    }

    private var allowedFileImportTypes: [UTType] {
        switch activeFileImport {
        case .serverConnection:
            return [.clipmanServerConnection, .json, .data]
        case .privateAuthority:
            return [.x509Certificate, .data]
        case .historyBackup, .none:
            return [.data]
        }
    }

    private func beginFileImport(_ kind: SettingsFileImport) {
        activeFileImport = kind
        showFileImporter = true
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard let kind = activeFileImport else { return }
        activeFileImport = nil

        do {
            guard let url = try result.get().first else { return }

            switch kind {
            case .serverConnection:
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard fileSize <= 65_536 else { throw ConnectionConfigError.fileTooLarge }
                pendingConnection = try ServerSettingsSanitizer.parseConnectionConfig(Data(contentsOf: url))
            case .privateAuthority:
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard fileSize <= 32 * 1024 else { throw ConnectionConfigError.authorityTooLarge }
                let pem = try String(contentsOf: url, encoding: .utf8)
                guard let authority = try ServerSettingsSanitizer.parseCertificateAuthority(pem, address: draft.serverURL) else {
                    throw ConnectionConfigError.invalidAuthority
                }
                pendingAuthority = authority
            case .historyBackup:
                guard !draft.historyPassword.isEmpty else {
                    throw CloudHistoryBackupError.unencryptedBackup
                }
                guard draft.historyPassword == app.settings.historyPassword else {
                    settingsValidationError = "Save the history password before restoring an encrypted backup."
                    return
                }
                let data = try CloudHistoryBackup.read(url)
                Task {
                    do {
                        try await app.mergeHistoryBackup(data)
                        backupMessage = "History backup merged."
                    } catch {
                        backupError = error.localizedDescription
                    }
                }
            }
        } catch {
            if (error as NSError).code == NSUserCancelledError { return }
            switch kind {
            case .historyBackup:
                backupError = error.localizedDescription
            case .serverConnection, .privateAuthority:
                connectionImportError = error.localizedDescription
            }
        }
    }

    private func shareConnectionDocument() {
        guard let data = connectionDocument?.data else {
            connectionExportError = "The server connection file could not be prepared."
            return
        }
        do {
            let file = try ServerConnectionShareFile.create(data: data)
            connectionShareFileForCleanup = file
            connectionShareFile = file
        } catch {
            connectionDocument = nil
            connectionExportError = error.localizedDescription
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var buildStamp: String {
        Bundle.main.object(forInfoDictionaryKey: "ClipmanBuildStampUtcMs") as? String ?? "Unknown"
    }

    private var formattedBuildTime: String {
        guard let milliseconds = Double(buildStamp) else { return "Unknown" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
    }
}

/// The read-mostly sync-rules screen of `sync-rules-spec.md` section 5: it shows
/// the channels and the devices the rules document defines, and lets the user
/// change only this device's subscription. Creating, editing and deleting
/// channels stays on desktop and the command line, where the editing client can
/// re-route the affected entries immediately.
private struct SyncRulesSettingsSection: View {
    @ObservedObject var app: ClipmanAppModel
    @State private var subscribeToAll = true
    @State private var selectedKeys: Set<String> = []
    @State private var loadedStamp: Int64 = .min
    @State private var isSaving = false
    @State private var errorMessage = ""

    var body: some View {
        Section("Sync channels") {
            Text("Enable sync rules only after every device runs a Clipman version that supports them. Older devices will continue to sync the main history only.")
                .font(.footnote)
            if !app.syncRules.available {
                Text("Sync channels become available when this device stores history on Clipman Server.")
                    .font(.footnote)
            } else if !app.syncRules.isEnabled {
                Text("Sync rules are off for this history. Use Clipman on a desktop computer or the command line to create channels and turn them on.")
                    .font(.footnote)
            } else {
                subscriptionControls
                deviceDirectory
            }
        }
        .task {
            await app.refreshSyncRules()
            reloadIfNeeded()
        }
        .onChange(of: app.syncRules) { _ in
            reloadIfNeeded()
        }
    }

    @ViewBuilder
    private var subscriptionControls: some View {
        Text("Channels are created on desktop. This screen changes only what this device downloads. The main history is always downloaded.")
            .font(.footnote)
        if app.syncRules.isReadOnly {
            Text("These sync rules were written by a newer version of Clipman, so this device can read them but not change them. Update Clipman here to edit them.")
                .font(.footnote)
        }
        Toggle("Download every channel", isOn: $subscribeToAll)
            .disabled(app.syncRules.isReadOnly || isSaving)
            .accessibilityHint("When on, this device downloads the main history and every sync channel.")
        ForEach(app.syncRules.channelKeys, id: \.self) { key in
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Download \(app.syncRules.channelName(key))", isOn: binding(for: key))
                    .disabled(subscribeToAll || app.syncRules.isReadOnly || isSaving)
                    .accessibilityHint(routeDescription(for: key))
                Text(routeDescription(for: key))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        Button("Save sync channels") { save() }
            .disabled(app.syncRules.isReadOnly || isSaving || !hasChanges)
            .accessibilityHint("Saves which channels this device downloads. Other devices are not changed.")
        if !errorMessage.isEmpty {
            Text(errorMessage)
                .font(.footnote)
                .accessibilityLabel("Sync channels error. \(errorMessage)")
        }
    }

    @ViewBuilder
    private var deviceDirectory: some View {
        ForEach(app.syncRules.document?.Devices ?? [], id: \.Name) { device in
            VStack(alignment: .leading, spacing: 2) {
                Text(device.Name)
                Text(subscriptionSummary(device))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Device \(device.Name) downloads \(subscriptionSummary(device))")
        }
        if !app.syncRules.deviceIsListed {
            Text("This device is not listed in the sync rules yet, so it downloads every channel. Clipman adds it on the next successful sync.")
                .font(.footnote)
        }
    }

    private func binding(for key: String) -> Binding<Bool> {
        Binding(
            get: { subscribeToAll || selectedKeys.contains(key) },
            set: { isOn in
                if isOn {
                    selectedKeys.insert(key)
                } else {
                    selectedKeys.remove(key)
                }
            }
        )
    }

    private var hasChanges: Bool {
        let subscribesToEverything = app.syncRules.subscribesToEverything
        if subscribeToAll { return !subscribesToEverything }
        if subscribesToEverything { return true }
        return selectedKeys != Set(app.syncRules.subscribedKeys)
    }

    private func reloadIfNeeded() {
        let stamp = app.syncRules.document?.UpdatedUnixMs ?? .min
        guard !isSaving, stamp != loadedStamp else { return }
        loadedStamp = stamp
        subscribeToAll = app.syncRules.subscribesToEverything
        selectedKeys = Set(app.syncRules.subscribedKeys)
    }

    private func save() {
        isSaving = true
        errorMessage = ""
        let channels: [String]? = subscribeToAll
            ? nil
            : app.syncRules.channelKeys.filter { selectedKeys.contains($0) }
        Task {
            let failure = await app.saveSyncSubscription(channels)
            isSaving = false
            errorMessage = failure ?? ""
            reloadIfNeeded()
        }
    }

    private func routeDescription(for key: String) -> String {
        guard let channel = app.syncRules.document?.Channels.first(where: {
            SyncRuleEngine.channelKey($0.Name) == key
        }) else {
            return "No routing conditions."
        }
        var parts: [String] = []
        if let groups = channel.Route.Groups, !groups.isEmpty {
            parts.append("Groups: \(groups.joined(separator: ", "))")
        }
        if let devices = channel.Route.SourceDevices, !devices.isEmpty {
            parts.append("Devices: \(devices.joined(separator: ", "))")
        }
        if let kind = channel.Route.Kind, kind == SyncRuleEngine.richTextImagesKind {
            parts.append("Entries that contain an embedded image")
        }
        return parts.isEmpty ? "No routing conditions." : parts.joined(separator: ". ")
    }

    private func subscriptionSummary(_ device: SyncDevice) -> String {
        if device.Channels.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "*" }) {
            return "Every channel"
        }
        let names = device.Channels
            .map { app.syncRules.channelName(SyncRuleEngine.normalized($0)) }
            .filter { !$0.isEmpty }
        return names.isEmpty ? "Main history only" : names.joined(separator: ", ")
    }
}

private struct TipJarSettingsSection: View {
    @ObservedObject var tipJar: TipJarStore

    var body: some View {
        Section("Support Clipman") {
            Text("Tips are optional in-app purchases and do not unlock features or content.")
                .font(.footnote)
            if tipJar.isLoading || !tipJar.hasLoaded {
                ProgressView("Loading Tip Options")
            } else if tipJar.products.isEmpty {
                Text("Tip options are currently unavailable. No features are affected.")
                    .font(.footnote)
                Button("Retry Loading Tip Options") {
                    Task { await tipJar.loadProducts() }
                }
            } else {
                ForEach(tipJar.products, id: \.id) { product in
                    Button(tipJar.buttonTitle(for: product)) {
                        Task { await tipJar.purchase(product) }
                    }
                    .disabled(tipJar.isPurchasing)
                    .accessibilityHint("Make an optional one-time tip through Apple. This unlocks nothing.")
                }
            }
            if !tipJar.message.isEmpty {
                Text(tipJar.message)
                    .font(.footnote)
            }
        }
    }
}
