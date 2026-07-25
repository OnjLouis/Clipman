import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var app: ClipmanAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ClipmanSettings.empty
    @State private var showServerConnection = false
    @State private var showConnectionImporter = false
    @State private var showConnectionExportWarning = false
    @State private var showConnectionExporter = false
    @State private var connectionDocument: ServerConnectionDocument?
    @State private var pendingConnection: ServerConnectionDetails?
    @State private var connectionImportError = ""
    @State private var connectionExportError = ""
    @State private var settingsValidationError = ""
    @StateObject private var tipJar = TipJarStore()

    var body: some View {
        NavigationStack {
            Form {
                Section("History storage") {
                    Picker("Storage mode", selection: $draft.storageMode) {
                        ForEach(MobileStorageMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(draft.storageMode == .local
                        ? "History is stored privately on this iPhone. Your server details remain saved for later."
                        : "History is cached on this iPhone and merged with Clipman Server. Offline changes retry automatically.")
                        .font(.footnote)
                }

                Section("Device") {
                    TextField("Device name", text: $draft.deviceName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    Toggle("Play sounds", isOn: $draft.soundsEnabled)
                    Toggle("Use haptics", isOn: $draft.hapticsEnabled)
                    Toggle("Enable links history", isOn: $draft.linksEnabled)
                    Toggle("Copy latest remote item to iOS clipboard", isOn: $draft.autoCopyRemote)
                    Toggle("Offer to add current clipboard on launch", isOn: $draft.addClipboardOnLaunch)
                    Toggle("Require biometric or device authentication", isOn: $draft.requireAuthentication)
                        .accessibilityHint("When enabled, Clipman asks for Face ID, Touch ID, or the device passcode whenever the app returns to the foreground.")
                }

                Section("Server connection") {
                    Text(serverIsConfigured ? "Server connection is configured." : "Server connection needs setup.")
                        .foregroundStyle(serverIsConfigured ? .secondary : .primary)
                    Button(showServerConnection ? "Hide server connection" : "Show server connection") {
                        showServerConnection.toggle()
                    }
                    Button("Import server connection file") {
                        showConnectionImporter = true
                    }
                    .accessibilityHint("Choose a Clipman Server connection file, review its address, then save settings.")
                    Button("Export server connection file") {
                        do {
                            connectionDocument = ServerConnectionDocument(data: try ServerSettingsSanitizer.connectionConfigData(
                                address: draft.serverURL,
                                token: draft.serverToken
                            ))
                            showConnectionExportWarning = true
                        } catch {
                            connectionExportError = error.localizedDescription
                        }
                    }
                    .accessibilityHint("Save the current server address and private access token to a Clipman Server connection file.")
                    if showServerConnection {
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

                if tipJar.isLoading || !tipJar.products.isEmpty {
                    TipJarSettingsSection(tipJar: tipJar)
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
                        guard draft.storageMode != .server || !draft.historyPassword.isEmpty else {
                            settingsValidationError = "Clipman Server requires a unique history password. Enter one before saving this connection."
                            showServerConnection = true
                            return
                        }
                        app.saveSettings(draft)
                        dismiss()
                    }
                }
            }
            .onAppear {
                draft = app.settings
                showServerConnection = !serverIsConfigured
                applyPendingConnectionImport()
            }
            .task {
                await tipJar.loadProducts()
            }
            .onChange(of: app.serverConnectionImportSequence) { _ in
                applyPendingConnectionImport()
            }
            .fileImporter(
                isPresented: $showConnectionImporter,
                allowedContentTypes: [.clipmanServerConnection, .json, .data],
                allowsMultipleSelection: false
            ) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard fileSize <= 65_536 else { throw ConnectionConfigError.fileTooLarge }
                    pendingConnection = try ServerSettingsSanitizer.parseConnectionConfig(Data(contentsOf: url))
                } catch {
                    connectionImportError = error.localizedDescription
                }
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
            .alert("Export private server connection?", isPresented: $showConnectionExportWarning) {
                Button("Export") { showConnectionExporter = true }
                Button("Cancel", role: .cancel) { connectionDocument = nil }
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
                    showServerConnection = true
                    pendingConnection = nil
                }
                Button("Cancel", role: .cancel) { pendingConnection = nil }
            } message: {
                Text("Server: \(pendingConnection?.address ?? "")\n\nThe token will remain hidden. Choose Save to apply this connection.")
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
            .alert("History password required", isPresented: Binding(
                get: { !settingsValidationError.isEmpty },
                set: { if !$0 { settingsValidationError = "" } }
            )) {
                Button("OK") { settingsValidationError = "" }
            } message: {
                Text(settingsValidationError)
            }
        }
        .accessibilityAction(.escape) {
            dismiss()
        }
    }

    private var serverIsConfigured: Bool {
        !draft.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func applyPendingConnectionImport() {
        let (details, errorMessage) = app.consumeServerConnectionImport()
        if let details {
            pendingConnection = details
        } else if !errorMessage.isEmpty {
            connectionImportError = errorMessage
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

private struct TipJarSettingsSection: View {
    @ObservedObject var tipJar: TipJarStore

    var body: some View {
        Section("Support Clipman") {
            Text("Tips are optional in-app purchases and do not unlock features or content.")
                .font(.footnote)
            if tipJar.products.isEmpty {
                ProgressView("Loading Tip Options")
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
