import SwiftUI
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let bg = UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 6/255, green: 9/255, blue: 15/255, alpha: 1)   // #06090F
                : UIColor(red: 244/255, green: 246/255, blue: 251/255, alpha: 1) // #F4F6FB
        }
        windowScene.windows.forEach { $0.backgroundColor = bg }
    }
}

@main
struct ClawMuxApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
