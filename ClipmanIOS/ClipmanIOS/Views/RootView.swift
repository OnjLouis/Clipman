import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: ClipmanAppModel

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
            if !app.isUnlocked {
                app.unlock()
            }
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
