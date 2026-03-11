import SwiftUI

@main
struct ClawMuxApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // Fills the UIWindow background so no black area is revealed
                // when the keyboard shifts content up
                .background(Color(UIColor { tc in
                    tc.userInterfaceStyle == .dark
                        ? UIColor(red: 0.024, green: 0.035, blue: 0.059, alpha: 1)  // 0x06090F
                        : UIColor(red: 0.957, green: 0.965, blue: 0.984, alpha: 1)  // 0xF4F6FB
                }).ignoresSafeArea())
        }
    }
}
