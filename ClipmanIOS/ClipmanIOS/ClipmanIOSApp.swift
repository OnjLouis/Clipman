import SwiftUI

@main
struct ClipmanIOSApp: App {
    @StateObject private var appModel = ClipmanAppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
        }
    }
}
