import WidgetKit
import SwiftUI

// MARK: - Walking Mode Control Widget
// Shows up in Action Button controls picker and Control Center.
// Tap to open ClawMux in Walking Mode.
// OpenWalkingModeIntent is in ClawMuxShared (shared with main app).

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
