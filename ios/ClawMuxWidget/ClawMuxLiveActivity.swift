import ActivityKit
import SwiftUI
import WidgetKit

struct ClawMuxLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClawMuxActivityAttributes.self) { context in
            lockScreenView(context: context)
                .widgetURL(URL(string: "voicehub://mic"))
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
                    HStack {
                        if !context.state.lastMessage.isEmpty {
                            Text(context.state.lastMessage)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Spacer()
                        }
                        Link(destination: URL(string: "voicehub://mic")!) {
                            modeButton(inputMode: context.state.inputMode, status: context.state.status)
                        }
                    }
                }
            } compactLeading: {
                Circle()
                    .fill(statusColor(context.state.status))
                    .frame(width: 10, height: 10)
            } compactTrailing: {
                HStack(spacing: 4) {
                    Text(context.state.voiceName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Image(systemName: modeIcon(context.state.inputMode))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
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
        context: ActivityViewContext<ClawMuxActivityAttributes>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claw Hub")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(context.state.voiceName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
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
            if !context.state.lastMessage.isEmpty {
                Text(context.state.lastMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Link(destination: URL(string: "voicehub://mic")!) {
                lockScreenButton(inputMode: context.state.inputMode, status: context.state.status)
            }
        }
        .padding(16)
        .background(Color(red: 0.1, green: 0.1, blue: 0.18))
    }

    // MARK: - Mode Button (Dynamic Island)

    @ViewBuilder
    private func modeButton(inputMode: String, status: ClawMuxStatus) -> some View {
        switch inputMode {
        case "ptt":
            HStack(spacing: 5) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 12))
                Text("Hold to Talk")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.white.opacity(0.12), in: Capsule())
        case "typing":
            Image(systemName: "keyboard")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .padding(8)
                .background(.white.opacity(0.08), in: Circle())
        default: // auto
            HStack(spacing: 5) {
                Image(systemName: status == .listening ? "waveform" : "mic.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(status == .listening ? Color(red: 0.9, green: 0.22, blue: 0.27) : .white)
                Text(status == .listening ? "Listening" : "Tap to Talk")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.white.opacity(0.12), in: Capsule())
        }
    }

    // MARK: - Lock Screen Button

    @ViewBuilder
    private func lockScreenButton(inputMode: String, status: ClawMuxStatus) -> some View {
        HStack(spacing: 8) {
            Image(systemName: inputMode == "typing" ? "keyboard" : "mic.fill")
                .font(.system(size: 14, weight: .semibold))
            Text(inputMode == "ptt" ? "Open to Talk" : inputMode == "typing" ? "Open to Type" : "Open App")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Helpers

    private func modeIcon(_ inputMode: String) -> String {
        switch inputMode {
        case "ptt": return "mic.circle"
        case "typing": return "keyboard"
        default: return "waveform"
        }
    }

    private func statusColor(_ status: ClawMuxStatus) -> Color {
        let hex = status.dotColorHex
        return Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
