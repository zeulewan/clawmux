import SwiftUI
import UniformTypeIdentifiers

// MARK: - InputBarView
// Extracted from ContentView.swift — Bottom Input Area, Voice Controls, Text Input Bar,
// PTT Text Input Bar, Waveform, Mic Button, and related helpers.

struct InputBarView: View {
    @ObservedObject var vm: ClawMuxViewModel
    @Binding var pttDragOffset: CGFloat
    @Binding var pttDragOffsetY: CGFloat
    @Binding var pttGestureCommitted: Bool
    @FocusState.Binding var pttTextFieldFocused: Bool
    @Binding var showFilePicker: Bool
    @FocusState private var typingFieldFocused: Bool
    /// When true, always renders the text input bar regardless of vm.inputMode (used for group chat).
    var forceTypingMode: Bool = false

    var body: some View {
        Group {
            if forceTypingMode || vm.typingMode {
                textInputBar.transition(.opacity)
            } else if vm.pushToTalk && vm.showPTTTextField {
                pttTextInputBar.transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                voiceControlBar.transition(.opacity)
            }
        }
        .padding(.leading, 48)
        .padding(.bottom, 8)
        .background {
            if #available(iOS 26, *) {
                Color.clear.glassEffect(.regular, in: .rect).ignoresSafeArea(edges: .bottom)
            } else {
                Color.canvas1.opacity(0.96).ignoresSafeArea(edges: .bottom)
            }
        }
    }

    // MARK: - Voice Controls

    private var voiceControlBar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if vm.isRecording {
                    waveformView
                        .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                }

                if vm.showTranscriptPreview {
                    HStack(spacing: 8) {
                        Button { vm.clearTranscriptPreview() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.cTextTer)
                                .frame(width: 24, height: 24)
                                .background(Color.glass, in: Circle())
                        }
                        Group {
                            if vm.isTranscribingPreview {
                                HStack(spacing: 6) {
                                    ProgressView().scaleEffect(0.7)
                                    Text("Transcribing…").font(.system(size: 13)).foregroundStyle(Color.cTextTer)
                                }
                            } else if let err = vm.pttTranscriptionError {
                                Text(err).font(.system(size: 13)).foregroundStyle(Color.cWarning)
                            } else {
                                Text(vm.transcriptPreviewText)
                                    .font(.system(size: 13)).foregroundStyle(Color.cText).lineLimit(3)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .onTapGesture { if vm.pushToTalk { vm.tapTranscriptToEdit() } }

                        if vm.pushToTalk {
                            Button { vm.sendTranscriptPreview() } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(
                                        vm.transcriptPreviewText.isEmpty || vm.isTranscribingPreview
                                        ? Color.cTextTer : Color.cAccent)
                            }
                            .disabled(vm.transcriptPreviewText.isEmpty || vm.isTranscribingPreview)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 4)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                // Main row: cancel / mic / interrupt
                HStack(alignment: .center) {
                    if vm.isRecording && !vm.pushToTalk {
                        // Cancel recording (x) — matches web #mic-cancel (46×46, red, in mic-wrapper)
                        Button { vm.cancelRecording() } label: {
                            Image(systemName: "xmark").font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Color.cDanger)
                                .frame(width: 46, height: 46)
                                .background(Color.cDanger.opacity(0.10), in: Circle())
                                .overlay(Circle().strokeBorder(Color.cDanger.opacity(0.30), lineWidth: 1))
                        }
                        .frame(width: 60, height: 46)  // match idle placeholder width
                        .transition(.scale.combined(with: .opacity))
                    } else if vm.isRecording && vm.pushToTalk {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                            Text("Cancel").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(pttDragOffset < -80 ? Color.cDanger : Color.cTextTer)
                        .opacity(pttDragOffset < -10 ? min(1, Double(-pttDragOffset - 10) / 60) : 0.3)
                        .frame(width: 60).transition(.opacity)
                    } else if vm.isPlaying || vm.isPlaybackPaused {
                        // Transport pause — matches web #transport-pause (36×36, circular btn-icon)
                        Button {
                            if vm.isPlaybackPaused { vm.resumePlayback() } else { vm.pausePlayback() }
                        } label: {
                            Image(systemName: vm.isPlaybackPaused ? "play.fill" : "pause.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.cTextSec)
                                .frame(width: 36, height: 36)
                                .background(Color.cCard, in: Circle())
                                .overlay(Circle().strokeBorder(Color.cBorder, lineWidth: 1))
                        }
                        .frame(width: 60, height: 46)  // match idle placeholder width
                        .transition(.scale.combined(with: .opacity))
                    } else {
                        Color.clear.frame(width: 60, height: 46)
                    }

                    Spacer()

                    Group {
                        if vm.pushToTalk {
                            micButtonVisual
                                .contentShape(Circle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { v in
                                            if vm.showPTTTextField || vm.showTranscriptPreview || pttGestureCommitted { return }
                                            let dx = v.translation.width, dy = v.translation.height
                                            if dy < -60 && abs(dx) < 40 && vm.isRecording {
                                                pttGestureCommitted = true; vm.pttSwipeUpSend(); return
                                            }
                                            if dx < -80 && abs(dy) < 40 && vm.isRecording {
                                                pttGestureCommitted = true; vm.cancelRecording(); return
                                            }
                                            if dx > 60 && abs(dy) < 40 {
                                                pttGestureCommitted = true; vm.enterPTTTextMode(); return
                                            }
                                            vm.pttPressed()
                                            if vm.isRecording { pttDragOffset = dx; pttDragOffsetY = dy }
                                        }
                                        .onEnded { _ in
                                            if !pttGestureCommitted { vm.pttReleased() }
                                            pttDragOffset = 0; pttDragOffsetY = 0; pttGestureCommitted = false
                                        }
                                )
                        } else {
                            Button(action: vm.micAction) { micButtonVisual }
                        }
                    }
                    .disabled(vm.micMuted && !vm.isPlaying && !vm.isRecording)
                    .opacity(vm.micMuted && !vm.isPlaying ? 0.45 : 1)

                    Spacer()

                    if vm.isRecording && vm.pushToTalk {
                        // PTT text-mode hint (swipe right gesture)
                        HStack(spacing: 4) {
                            Text("Aa").font(.system(size: 12, weight: .semibold))
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(pttDragOffset > 40 ? Color.cAccent : Color.cTextTer)
                        .opacity(pttDragOffset > 10 ? min(1, Double(pttDragOffset - 10) / 50) : 0.3)
                        .frame(width: 60).transition(.opacity)
                    } else if let s = vm.activeSession, s.isThinking {
                        // Cancel thinking — only visible while agent is generating (thinking/processing/compacting)
                        Button { vm.sendInterrupt() } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color.cDanger)
                                .frame(width: 46, height: 46)
                                .background(Color.cDanger.opacity(0.10), in: Circle())
                                .overlay(Circle().strokeBorder(Color.cDanger.opacity(0.30), lineWidth: 1))
                        }
                        .transition(.scale.combined(with: .opacity))
                        .frame(width: 60)
                    } else {
                        Color.clear.frame(width: 60, height: 44)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 14)

                // Status row — mirrors web #controls-status (grid-row: 3, centered, full-width)
                if !vm.statusText.isEmpty {
                    Text(vm.statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 8).padding(.top, 0).padding(.bottom, 4)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background {
                // Pill glass — contained within its frame, does NOT bleed off-screen.
                // The outer padding below provides the float gap above the home indicator.
                if #available(iOS 26, *) {
                    Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.ultraThinMaterial)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: vm.isRecording)
        }
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 8)
    }

    // MARK: - Text Input Bar

    private var textInputBar: some View {
        // Mirrors web #text-input-bar: single row [text-stop?] [textarea] [send]
        // Container: padding 8px 12px, border-radius 20px, glass/blur
        HStack(alignment: .bottom, spacing: 8) {
            // Stop button — mirrors web #text-stop (38x38, red, in-flow, shown when agent working or speaking)
            if let s = vm.activeSession, s.isThinking || s.state == .starting || s.isSpeaking {
                Button { vm.sendInterrupt() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.cDanger)
                        .frame(width: 38, height: 38)
                        .background(Color.cDanger.opacity(0.10), in: Circle())
                        .overlay(Circle().strokeBorder(Color.cDanger.opacity(0.30), lineWidth: 1))
                }
                .transition(.scale.combined(with: .opacity))
            }

            // File attach button — mirrors web drag-and-drop upload (POST /api/sessions/:id/upload)
            Button { showFilePicker = true } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.cTextTer)
                    .frame(width: 32, height: 32)
            }

            // Text input — mirrors web #text-input (flex:1, transparent, padding 8px 4px)
            TextField("Type a message...", text: $vm.typingText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...5)
                .foregroundStyle(Color.cText)
                .padding(.horizontal, 4).padding(.vertical, 8)
                .submitLabel(.return)
                .focused($typingFieldFocused)

            // Send button — mirrors web #text-send (38x38, blue circle)
            Button { vm.sendText() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(
                        vm.typingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? Color.cTextTer : Color(hex: 0x007AFF))
            }
            .disabled(vm.typingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background {
            if #available(iOS 26, *) {
                Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.glassBorder, lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 8)  // wider margins clear rounded screen corners
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                vm.uploadFile(url: url)
            }
        }
    }

    // MARK: - PTT Text Input Bar

    private var pttTextInputBar: some View {
        VStack(spacing: 6) {
            if vm.isRecording { waveformView }
            HStack(spacing: 10) {
                Button { vm.dismissPTTTextField() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.cTextTer)
                        .frame(width: 32, height: 32).background(Color.glass, in: Circle())
                }
                Button { vm.isRecording ? vm.stopRecording() : vm.startRecording() } label: {
                    Image(systemName: vm.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(vm.isRecording ? Color.cDanger : Color.cAccent)
                }.disabled(vm.isTranscribing)

                if vm.isTranscribing {
                    ProgressView().frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Edit message…", text: $vm.pttPreviewText, axis: .vertical)
                            .textFieldStyle(.plain).font(.subheadline).lineLimit(1...5)
                            .foregroundStyle(Color.cText)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Color.glass, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .focused($pttTextFieldFocused)
                            .submitLabel(.send)
                            .onSubmit { vm.sendPreviewText() }
                        if let err = vm.pttTranscriptionError {
                            Text(err).font(.system(size: 10)).foregroundStyle(Color.cTextTer).padding(.horizontal, 12)
                        }
                    }
                }

                Button { vm.sendPreviewText() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
                        .foregroundStyle(
                            vm.pttPreviewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.cTextTer : Color.cAccent)
                }
                .disabled(vm.pttPreviewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isTranscribing)
            }
            .padding(.horizontal, 14).padding(.bottom, 8)
        }
        .background {
            if #available(iOS 26, *) {
                Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.ultraThinMaterial)
            }
        }
        .padding(.horizontal, 8).padding(.bottom, 4)
        .onAppear { pttTextFieldFocused = true }
    }

    // MARK: - Waveform

    private var waveformView: some View {
        let waveColor = vm.activeSession.map { voiceColor($0.voice) } ?? Color.cAccent
        return SpectrumWaveformView(spectrum: vm.spectrumSource, color: waveColor)
            .frame(height: 48)
            .padding(.horizontal, 16).padding(.vertical, 4)
    }

    // MARK: - Mic Button

    private var micButtonVisual: some View {
        ZStack {
            // Main button circle — matches web mobile #mic (80px)
            Circle()
                .fill(micColor)
                .frame(width: 80, height: 80)
                .shadow(color: micColor.opacity(0.5), radius: 16, y: 4)
            // Inner highlight
            Circle()
                .fill(LinearGradient(
                    colors: [.white.opacity(0.18), .clear],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 80, height: 80)
            Image(systemName: micIcon)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 80, height: 80)
    }

    private var micIcon: String {
        if vm.isPlaying   { return "hand.raised.fill" }
        if vm.isRecording { return "arrow.up.circle.fill" }
        if vm.micMuted    { return "mic.slash.fill" }
        return "mic.fill"
    }

    private var micColor: Color {
        if vm.isPlaying   { return .cWarning }
        if vm.isRecording { return .cSuccess }
        if vm.micMuted    { return .cDanger }
        return Color(hex: 0x2563EB)  // blue matching user bubble
    }

    // MARK: - Helpers

    private var statusColor: Color {
        if vm.isRecording { return .cSuccess }   // green: recording (web: var(--green))
        if vm.isPlaying   { return .cWarning }   // orange: interruptable (web: var(--orange))
        return .cTextSec                          // default: processing/thinking (web: text-tertiary default)
    }
}

// MARK: - Spectrum Waveform View

/// Exponential smoother with separate per-band attack and decay alphas.
/// Bass has more inertia (slow attack/decay); treble is snappier.
/// Uses a reference type so mutations don't trigger SwiftUI redraws.
private final class BandSmoother {
    var smooth: [CGFloat] = Array(repeating: 0, count: SpectrumProcessor.bandCount)
    // Attack alpha: fraction of gap closed per frame (bass=0.20, treble=0.45)
    private let attackAlpha: [CGFloat] = (0..<SpectrumProcessor.bandCount).map { b in
        0.20 + CGFloat(b) / CGFloat(SpectrumProcessor.bandCount - 1) * 0.25
    }
    // Decay alpha: slower than attack for natural release (bass=0.06, treble=0.22)
    private let decayAlpha: [CGFloat] = (0..<SpectrumProcessor.bandCount).map { b in
        0.06 + CGFloat(b) / CGFloat(SpectrumProcessor.bandCount - 1) * 0.16
    }

    func update(toward target: [CGFloat]) {
        guard target.count == smooth.count else { return }
        for i in 0..<smooth.count {
            let alpha = target[i] > smooth[i] ? attackAlpha[i] : decayAlpha[i]
            smooth[i] += alpha * (target[i] - smooth[i])
        }
    }
}

/// Renders a smooth continuous frequency curve using Catmull-Rom spline
/// (converted to cubic bezier). The line floats at the vertical center
/// at silence and peaks upward with each band's amplitude.
private struct SpectrumWaveformView: View {
    @ObservedObject var spectrum: SpectrumBandSource
    let color: Color
    @State private var smoother = BandSmoother()

    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { context, size in
                smoother.update(toward: spectrum.bands)
                let smoothed = smoother.smooth
                let count = smoothed.count
                guard count >= 2 else { return }

                let midY  = size.height / 2
                let amp   = size.height * 0.42   // max upward swing from center

                // Map each band to a 2D point (x spread across width, y = amplitude above midY)
                let pts: [CGPoint] = (0..<count).map { i in
                    CGPoint(
                        x: CGFloat(i) / CGFloat(count - 1) * size.width,
                        y: midY - smoothed[i] * amp
                    )
                }

                // Build smooth path using Catmull-Rom → cubic bezier conversion:
                // For segment pts[i]→pts[i+1], control points are derived from
                // neighboring points so the curve passes smoothly through every band.
                var path = Path()
                path.move(to: pts[0])
                for i in 0..<count - 1 {
                    let p0 = i > 0 ? pts[i - 1] : pts[i]
                    let p1 = pts[i]
                    let p2 = pts[i + 1]
                    let p3 = i + 2 < count ? pts[i + 2] : pts[i + 1]
                    let cp1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6,
                                      y: p1.y + (p2.y - p0.y) / 6)
                    let cp2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6,
                                      y: p2.y - (p3.y - p1.y) / 6)
                    path.addCurve(to: p2, control1: cp1, control2: cp2)
                }

                let avgLevel = smoothed.reduce(0, +) / CGFloat(count)
                context.stroke(path,
                               with: .color(color.opacity(0.45 + avgLevel * 0.55)),
                               lineWidth: 1.5)
            }
        }
    }
}
