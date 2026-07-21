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
    }
}

struct ClipboardImportView: View {
    @EnvironmentObject private var app: ClipmanAppModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Add Clipboard Text")
                    .font(.largeTitle)
                    .bold()
                Text("Choose Paste to add the current iOS clipboard text to Clipman, or Cancel to leave history unchanged.")
                    .multilineTextAlignment(.center)
                PasteButton(payloadType: String.self) { values in
                    app.addPastedClipboardText(values.first)
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel") {
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
                Text("Clipman Locked")
                    .font(.largeTitle)
                    .bold()
                Text("Unlock to access clipboard history.")
                    .font(.body)
                Button("Unlock") {
                    app.unlock()
                }
                .buttonStyle(.borderedProminent)
                Text(app.status)
                    .font(.callout)
            }
            .padding()
            .navigationTitle("Clipman")
        }
    }
}
