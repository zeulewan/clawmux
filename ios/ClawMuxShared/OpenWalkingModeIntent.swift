import AppIntents
import Foundation

// Shared between main app and widget extension so perform() runs in the app process
// (openAppWhenRun = true) and can post notifications to activate walking mode.

extension Notification.Name {
    static let activateWalkingMode = Notification.Name("activateWalkingMode")
}

@available(iOS 18.0, *)
struct OpenWalkingModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Walking Mode"
    static let description: IntentDescription = "Opens ClawMux in walking mode for hands-free voice interaction."
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .activateWalkingMode, object: nil)
        return .result()
    }
}
