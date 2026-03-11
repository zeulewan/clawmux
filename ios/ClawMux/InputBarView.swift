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
    }

    // MARK: - Voice Controls

    private var voiceControlBar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if vm.isRecording {
                    waveformView.transition(.opacity.combined(with: .move(edge: .bottom)))
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
                    } else if let s = vm.activeSession,
                        s.isThinking || s.state == .starting || s.isSpeaking
                    {
                        // Interrupt button — mirrors web #voice-stop (red, 46×46)
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
        // Fully transparent outside the pill — body ZStack canvas1 covers the safe area zone.
        // Pill has its own glassEffect background; no outer background needed.
        .padding(.horizontal, 16).padding(.top, 4)
        .ignoresSafeArea(edges: .bottom)
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
                .submitLabel(.send)
                .onSubmit { vm.sendText() }
                .focused($typingFieldFocused)

            // Keyboard dismiss button — only visible when keyboard is up, moves with pill
            if typingFieldFocused {
                Button { typingFieldFocused = false } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.cTextSec)
                        .frame(width: 32, height: 32)
                }
                .transition(.opacity)
            }

            // Send button — mirrors web #text-send (38x38, blue circle)
            Button { vm.sendText() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(
                        vm.typingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? Color.cTextTer : Color.cAccent)
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
        return TimelineView(.animation) { _ in
            let bands = vm.spectrumBands
            Canvas { context, size in
                let count = bands.count
                guard count > 0 else { return }
                let barW: CGFloat = 8
                let gap: CGFloat = 4
                let totalW = CGFloat(count) * barW + CGFloat(count - 1) * gap
                let startX = (size.width - totalW) / 2
                for i in 0..<count {
                    let level = bands[i]
                    let h = max(3, level * (size.height - 4))
                    let x = startX + CGFloat(i) * (barW + gap)
                    let y = size.height - h
                    let rect = CGRect(x: x, y: y, width: barW, height: h)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 2),
                        with: .color(waveColor.opacity(0.35 + level * 0.65))
                    )
                }
            }
        }
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
