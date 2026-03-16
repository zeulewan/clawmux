import AppIntents
import WidgetKit
import SwiftUI

// MARK: - Walking Mode Control Widget
// Shows up in Action Button controls picker and Control Center.
// Tap to open ClawMux in Walking Mode.

@available(iOS 18.0, *)
struct WalkingModeControl: ControlWidget {
    static let kind = "com.zeul.clawmux.walking-mode-control"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenWalkingModeIntent()) {
                Label("Walking Mode", systemImage: "figure.walk")
            }
        }
        .displayName("Walking Mode")
        .description("Open ClawMux in hands-free walking mode with Puck.")
    }
}

// MARK: - App Intent

@available(iOS 18.0, *)
struct OpenWalkingModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Walking Mode"
    static let description: IntentDescription = "Opens ClawMux in walking mode for hands-free voice interaction."
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        // Opening the app with openAppWhenRun = true will trigger the URL handler
        // The app checks for this intent and activates walking mode
        return .result()
    }
}
