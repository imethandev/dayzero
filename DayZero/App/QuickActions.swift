import Observation
import UIKit

/// Home Screen quick actions (long-press the app icon): Flashlight and SOS.
@Observable
final class QuickActionCenter {
    static let shared = QuickActionCenter()
    /// Set when a quick action arrives; RootTabView consumes it.
    var pending: ToolID?

    static let flashlightType = AppInfo.bundleID + ".flashlight"
    static let sosType = AppInfo.bundleID + ".sos"

    static func install() {
        UIApplication.shared.shortcutItems = [
            UIApplicationShortcutItem(type: flashlightType, localizedTitle: "Flashlight", localizedSubtitle: "Turn the light on",
                                      icon: UIApplicationShortcutIcon(systemImageName: "flashlight.on.fill"), userInfo: nil),
            UIApplicationShortcutItem(type: sosType, localizedTitle: "SOS signal", localizedSubtitle: "Flash SOS with the LED",
                                      icon: UIApplicationShortcutIcon(systemImageName: "sos"), userInfo: nil),
        ]
    }

    @discardableResult
    func handle(_ item: UIApplicationShortcutItem) -> Bool {
        switch item.type {
        case Self.flashlightType: pending = .flashlight
        case Self.sosType: pending = .sos
        default: return false
        }
        return true
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem { QuickActionCenter.shared.handle(item) } // cold launch
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(QuickActionCenter.shared.handle(shortcutItem)) // app already running
    }
}
