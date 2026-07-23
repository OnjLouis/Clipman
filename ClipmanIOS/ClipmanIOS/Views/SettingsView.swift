import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var app: ClipmanAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ClipmanSettings.empty
    @State private var showServerConnection = false
    @State private var showConnectionImporter = false
    @State private var pendingConnection: ServerConnectionDetails?
    @State private var connectionImportError = ""

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

                Section("Behaviour") {
                    TextField("Device name", text: $draft.deviceName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    Toggle("Play sounds", isOn: $draft.soundsEnabled)
                    Toggle("Use haptics", isOn: $draft.hapticsEnabled)
                    Toggle("Enable links history", isOn: $draft.linksEnabled)
                    Toggle("Copy latest remote item to iOS clipboard", isOn: $draft.autoCopyRemote)
                    Toggle("Offer to add current clipboard on launch", isOn: $draft.addClipboardOnLaunch)
                    Stepper(value: $draft.refreshIntervalSeconds, in: 2...30, step: 1) {
                        Text("Refresh interval: \(Int(draft.refreshIntervalSeconds)) seconds")
                    }
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
