import ActivityKit
import SwiftUI
import WidgetKit

struct VoiceChatLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceChatActivityAttributes.self) { context in
            // Lock Screen
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor(context.state.status))
                            .frame(width: 10, height: 10)
                        Text(context.state.voiceName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.status.label)
                        .font(.system(size: 12))
                        .foregroundStyle(statusColor(context.state.status))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !context.state.lastMessage.isEmpty {
                        Text(context.state.lastMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } compactLeading: {
                Circle()
                    .fill(statusColor(context.state.status))
                    .frame(width: 10, height: 10)
            } compactTrailing: {
                Text(context.state.voiceName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            } minimal: {
                Circle()
                    .fill(statusColor(context.state.status))
                    .frame(width: 10, height: 10)
            }
        }
    }

    // MARK: - Lock Screen

    @ViewBuilder
    private func lockScreenView(
        context: ActivityViewContext<VoiceChatActivityAttributes>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Voice Hub")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor(context.state.status))
                        .frame(width: 8, height: 8)
                    Text(context.state.status.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(statusColor(context.state.status))
                }
            }
            Text(context.state.voiceName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            if !context.state.lastMessage.isEmpty {
                Text(context.state.lastMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .background(Color(red: 0.1, green: 0.1, blue: 0.18))
    }

    // MARK: - Helpers

    private func statusColor(_ status: VoiceChatStatus) -> Color {
        let hex = status.dotColorHex
        return Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
