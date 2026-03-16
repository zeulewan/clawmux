import SwiftUI
import WidgetKit

@main
struct ClawMuxWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClawMuxLiveActivity()
        if #available(iOS 18.0, *) {
            WalkingModeControl()
        }
    }
}
