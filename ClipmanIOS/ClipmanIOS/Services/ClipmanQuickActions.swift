import UIKit

enum ClipmanQuickAction: String {
    case addClipboard = "me.onj.clipman.ios.add-clipboard"
    case copyLatest = "me.onj.clipman.ios.copy-latest"
}

@MainActor
final class ClipmanQuickActionCenter {
    static let shared = ClipmanQuickActionCenter()

    private(set) var pendingAction: ClipmanQuickAction?

    func request(_ action: ClipmanQuickAction) {
        pendingAction = action
        NotificationCenter.default.post(name: .clipmanQuickActionRequested, object: nil)
    }

    func consume() -> ClipmanQuickAction? {
        defer { pendingAction = nil }
        return pendingAction
    }
}

final class ClipmanAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let shortcutItem = options.shortcutItem,
           let action = ClipmanQuickAction(rawValue: shortcutItem.type) {
            Task { @MainActor in
                ClipmanQuickActionCenter.shared.request(action)
            }
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = ClipmanSceneDelegate.self
        return configuration
    }

    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        guard let action = ClipmanQuickAction(rawValue: shortcutItem.type) else {
            completionHandler(false)
            return
        }
        Task { @MainActor in
            ClipmanQuickActionCenter.shared.request(action)
            completionHandler(true)
        }
    }
}

final class ClipmanSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        guard let action = ClipmanQuickAction(rawValue: shortcutItem.type) else {
            completionHandler(false)
            return
        }
        Task { @MainActor in
            ClipmanQuickActionCenter.shared.request(action)
            completionHandler(true)
        }
    }
}

extension Notification.Name {
    static let clipmanQuickActionRequested = Notification.Name("ClipmanQuickActionRequested")
}
