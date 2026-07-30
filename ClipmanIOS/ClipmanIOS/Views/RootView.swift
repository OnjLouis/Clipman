import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: ClipmanAppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if app.isUnlocked {
                HistoryView()
            } else {
                LockedView()
            }
        }
        .fullScreenCover(isPresented: $app.showingSettings) {
            SettingsView()
                .environmentObject(app)
        }
        .fullScreenCover(isPresented: $app.showingClipboardImport) {
            ClipboardImportView()
                .environmentObject(app)
        }
        .onAppear {
            app.sceneBecameActive()
        }
        .onOpenURL { url in
            app.openServerConnectionFile(url)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                app.sceneBecameActive()
            case .background:
                app.sceneMovedToBackground()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onChange(of: app.showingSettings) { isShowing in
            if !isShowing {
                app.settingsClosed()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipmanQuickActionRequested)) { _ in
            app.processPendingQuickAction()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipmanShortcutCompleted)) { notification in
            guard let message = notification.object as? String else { return }
            app.shortcutCompleted(message)
        }
    }
}

struct ClipboardImportView: View {
    @EnvironmentObject private var app: ClipmanAppModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Add Clipboard Content")
                    .font(.largeTitle)
                    .bold()
                Text("Choose Paste to add the current iOS clipboard text and available formatting to Clipman, or Cancel to leave history unchanged.")
                    .multilineTextAlignment(.center)
                    .accessibilityAction(.escape) {
                        app.cancelClipboardImport()
                    }
                Button("Cancel") {
                    app.cancelClipboardImport()
                }
                .accessibilityAction(.escape) {
                    app.cancelClipboardImport()
                }
                Button("Paste") {
                    app.addPastedClipboardPayload(MobileRichTextClipboard.readCurrent())
                }
                .buttonStyle(.borderedProminent)
                .accessibilityAction(.escape) {
                    app.cancelClipboardImport()
                }
            }
            .padding()
            .navigationTitle("Clipboard")
        }
        .accessibilityAction(.escape) {
            app.cancelClipboardImport()
        }
    }
}

struct LockedView: View {
    @EnvironmentObject private var app: ClipmanAppModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text(app.settings.requireAuthentication ? "Clipman Locked" : "Opening Clipman")
                    .font(.largeTitle)
                    .bold()
                Text(app.settings.requireAuthentication ? "Unlock to access clipboard history." : "Loading clipboard history.")
                    .font(.body)
                if app.settings.requireAuthentication {
                    Button("Unlock") {
                        app.unlock()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    ProgressView()
                        .accessibilityLabel("Loading clipboard history")
                }
                Text(app.status)
                    .font(.callout)
            }
            .padding()
            .navigationTitle("Clipman")
        }
    }
}
