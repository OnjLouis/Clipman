import SwiftUI

@main
struct ClipmanIOSApp: App {
    @UIApplicationDelegateAdaptor(ClipmanAppDelegate.self) private var appDelegate
    @StateObject private var appModel = ClipmanAppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
        }
    }
}
