import SwiftUI

// MARK: - Walking Mode View
// Minimal full-screen interface for hands-free voice interaction.
// All voice routes to Puck (am_puck). TTS plays responses.
// Swipe down or tap to exit.

struct WalkingModeView: View {
    @ObservedObject var vm: ClawMuxViewModel
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Activity indicator — pulses when Puck is thinking
                let puckSession = vm.sessions.first { $0.voice == "am_puck" }
                let isThinking = puckSession?.isThinking == true
                let isRecording = vm.isRecording

                ZStack {
                    // Outer pulse ring
                    Circle()
                        .strokeBorder(Color.white.opacity(isPulsing ? 0.3 : 0.05), lineWidth: 2)
                        .frame(width: 120, height: 120)
                        .scaleEffect(isPulsing ? 1.1 : 1.0)
                        .animation(
                            (isThinking || isRecording)
                                ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                                : .default,
                            value: isPulsing
                        )

                    // Inner circle
                    Circle()
                        .fill(isRecording ? Color.red.opacity(0.3) : Color.white.opacity(0.08))
                        .frame(width: 80, height: 80)

                    // Icon
                    Image(systemName: isRecording ? "mic.fill" : isThinking ? "ellipsis" : "waveform")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(isRecording ? .red : .white.opacity(0.6))
                }

                Text("Walking Mode")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .tracking(1.5)

                // Status text
                if let s = puckSession {
                    if isThinking {
                        Text(s.activity.isEmpty ? "Thinking..." : s.activity)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.white.opacity(0.3))
                            .lineLimit(1)
                            .transition(.opacity)
                    }
                }

                Spacer()
                Spacer()

                // Swipe hint
                VStack(spacing: 4) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Swipe down to exit")
                        .font(.system(size: 11))
                }
                .foregroundStyle(Color.white.opacity(0.2))
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            isPulsing = true
            // Ensure Puck session exists and is active
            if vm.sessions.first(where: { $0.voice == "am_puck" }) == nil {
                vm.spawnSession(voiceId: "am_puck")
            }
            // Switch to Puck
            if let puck = vm.sessions.first(where: { $0.voice == "am_puck" }) {
                vm.switchToSession(puck.id)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 50)
                .onEnded { value in
                    if value.translation.height > 100 {
                        vm.deactivateWalkingMode()
                    }
                }
        )
        .onTapGesture(count: 2) {
            vm.deactivateWalkingMode()
        }
        .statusBarHidden()
    }
}
