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
