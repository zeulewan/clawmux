import SwiftUI
import UniformTypeIdentifiers

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var vm = ClawMuxViewModel()
    @State private var isPulsing      = false
    @State private var showResetConfirm      = false
    @State private var resetVoiceId: String? = nil
    @State private var showModelRestartConfirm = false
    @State private var pendingModelSwitch      = ""
    @State private var showEffortRestartConfirm = false
    @State private var pendingEffortSwitch      = ""
    @State private var showModelPicker         = false
    @State private var showEffortPicker        = false
    @State private var pttDragOffset:  CGFloat = 0
    @State private var pttDragOffsetY: CGFloat = 0
    @State private var pttGestureCommitted     = false
    @FocusState private var pttTextFieldFocused: Bool
    @State private var showCopiedToast         = false
    @State private var thinkingExpanded        = false
    @State private var collapsedProjects:       Set<String> = []
    @State private var expandedAgentMsgIds:    Set<UUID> = []
    @State private var isAtBottom:             Bool = true
    @State private var isLoadingOlder:         Bool = false
    @State private var sidebarExpanded:        Bool = false
    @State private var showFilePicker:         Bool = false
    @State private var showCreateGroupChat     = false
    @State private var newGroupChatName        = ""
    @State private var voiceTintColor: Color   = .clear  // stable tint, updated via onChange only

    var body: some View {
        // Body + Sidebar ZStack — header floats above as safeAreaInset so content scrolls behind it
        ZStack(alignment: .leading) {
            // mainAreaView full width — scroll content extends behind sidebar glass for proper blur
            mainAreaView
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Dim overlay behind expanded sidebar (starts at sidebar edge)
            if sidebarExpanded {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .padding(.leading, 48)
                    .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { sidebarExpanded = false } }
                    .transition(.opacity)
            }

            // Sidebar glass overlay — blurs scroll content behind it
            SidebarView(
                vm: vm,
                sidebarExpanded: $sidebarExpanded,
                isPulsing: $isPulsing,
                collapsedProjects: $collapsedProjects,
                showResetConfirm: $showResetConfirm,
                resetVoiceId: $resetVoiceId,
                showCreateGroupChat: $showCreateGroupChat,
                newGroupChatName: $newGroupChatName
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Header as overlay: floats above content so messages scroll behind the glass bar
        .overlay(alignment: .top) {
            topBarView
        }
        .background(Color.canvas1.ignoresSafeArea())
        .onAppear { isPulsing = true }
        .sheet(isPresented: $vm.showSettings) { SettingsView(vm: vm) }
        .sheet(isPresented: $vm.showNotes) { NotesPanelView(baseURL: vm.httpBaseURL()) { vm.showNotes = false } }
        .onOpenURL { vm.handleOpenURL($0) }
        .alert("Reset History", isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) {
                if let vid = resetVoiceId { vm.resetHistory(voiceId: vid) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let name = ALL_VOICES.first { $0.id == resetVoiceId }?.name ?? "this voice"
            Text("Clear all history for \(name)? This also ends the active session.")
        }
        .alert("Switch Model", isPresented: $showModelRestartConfirm) {
            Button("Restart", role: .destructive) { vm.restartWithModel(pendingModelSwitch) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will restart the session with \(pendingModelSwitch.capitalized). The conversation will be preserved.")
        }
        .alert("Switch Effort", isPresented: $showEffortRestartConfirm) {
            Button("Restart", role: .destructive) { vm.restartWithEffort(pendingEffortSwitch) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Switch to \(pendingEffortSwitch.capitalized) effort? This will restart the session. The conversation will be preserved.")
        }
        .alert("Error", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) { Button("OK") { vm.errorMessage = nil }
        } message: { Text(vm.errorMessage ?? "") }
        .alert("New Group Chat", isPresented: $showCreateGroupChat) {
            TextField("Group name", text: $newGroupChatName)
            Button("Create") { vm.createGroupChat(name: newGroupChatName) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Enter a name for the new group chat.") }
    }

    // MARK: - Split Layout

    // Top bar — full-width header always above the sidebar ZStack
    private var topBarView: some View {
        Group {
            if vm.activeGroupName != nil {
                groupChatHeader
            } else {
                chatHeader  // handles nil activeSession gracefully (shows just conn dot)
            }
        }
    }

    private var mainAreaView: some View {
        Group {
            if vm.isFocusMode {
                focusModeView
            } else if vm.activeGroupName != nil {
                groupChatMainView
            } else if vm.activeSessionId != nil {
                chatMainView
            } else {
                WelcomeView(
                    vm: vm,
                    isPulsing: $isPulsing,
                    collapsedProjects: $collapsedProjects,
                    sidebarExpanded: $sidebarExpanded,
                    showResetConfirm: $showResetConfirm,
                    resetVoiceId: $resetVoiceId
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Voice color background tint — uses @State so animation only fires on explicit onChange,
        // not on every ViewModel re-render (fixes random color flicker on iOS 26)
        .background(voiceTintColor.opacity(0.10))
        .onChange(of: vm.activeSessionId) { _, _ in
            withAnimation(.easeInOut(duration: 0.4)) {
                voiceTintColor = vm.activeSession.map { voiceColor($0.voice) } ?? .clear
            }
        }
    }

    private var focusModeView: some View {
        VStack(spacing: 16) {
            Image(systemName: "scope")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(Color.cTextTer)
            Text("Focus Mode")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.cTextSec)
            Text("Tap an agent in the sidebar to switch.")
                .font(.system(size: 13))
                .foregroundStyle(Color.cTextTer)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.leading, 48)
    }

    // MARK: - Group Chat View

    private var groupChatMainView: some View {
        GroupChatScrollView(vm: vm, showCopiedToast: $showCopiedToast)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) { textInputBar.padding(.leading, 48) }
    }

    private var groupChatHeader: some View {
        GroupChatHeaderView(vm: vm)
    }

    // MARK: - Chat Main View

    private var chatMainView: some View {
        ZStack(alignment: .top) {
            if vm.showDebug {
                DebugView(vm: vm)
            } else {
                chatScrollArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .bottom, spacing: 0) { bottomInputArea }
            }
            // Copy toast
            if showCopiedToast {
                Text("Copied")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.cText)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background {
                        if #available(iOS 26, *) {
                            Color.clear.glassEffect(.regular, in: Capsule())
                        } else {
                            Color.canvas2.opacity(0.90).background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                    .overlay(Capsule().strokeBorder(Color.cBorder, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.4), radius: 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                    .padding(.top, 12)
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: showCopiedToast)
    }

    // MARK: - Chat Header (mirrors web #header mobile layout)
    // Left: agent name · model · effort · mode toggle
    // Right: connection dot (web header-pill)
    // Settings/Notes hidden from header — they live in the sidebar tray

    private var chatHeader: some View {
        let color = vm.activeSession.map { voiceColor($0.voice) } ?? Color.cTextSec
        return HStack(spacing: 8) {
            if let s = vm.activeSession {
                // Agent name — mirrors web #active-voice
                Text(vm.showDebug ? "Debug" : s.label)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(color)  // agent voice color
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .layoutPriority(1)  // protect name from being squeezed by fixed-size pills

                // Model label — confirmationDialog avoids iOS 26 Menu portal blocker
                Button { showModelPicker = true } label: {
                    Text(modelName(s.model))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.cTextSec)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.glass, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.glassBorder, lineWidth: 0.5))
                        .fixedSize()
                }
                .confirmationDialog("Select Model", isPresented: $showModelPicker) {
                    let cur = vm.activeSession?.model ?? ""
                    Button(cur == "opus" || cur.isEmpty ? "Opus ✓" : "Opus") {
                        if cur != "opus" { pendingModelSwitch = "opus"; showModelRestartConfirm = true }
                    }
                    Button(cur == "sonnet" ? "Sonnet ✓" : "Sonnet") {
                        if cur != "sonnet" { pendingModelSwitch = "sonnet"; showModelRestartConfirm = true }
                    }
                    Button(cur == "haiku" ? "Haiku ✓" : "Haiku") {
                        if cur != "haiku" { pendingModelSwitch = "haiku"; showModelRestartConfirm = true }
                    }
                    Button("Cancel", role: .cancel) {}
                }

                // Effort label — confirmationDialog avoids iOS 26 Menu portal blocker
                if s.model != "haiku" {
                    Button { showEffortPicker = true } label: {
                        Text(s.effort.isEmpty ? "High" : s.effort.capitalized)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.cTextTer)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.glass, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.glassBorder, lineWidth: 0.5))
                            .fixedSize()
                    }
                    .confirmationDialog("Select Effort", isPresented: $showEffortPicker) {
                        ForEach(["high","medium","low"], id: \.self) { level in
                            Button(s.effort == level || (level == "high" && s.effort.isEmpty) ? "\(level.capitalized) ✓" : level.capitalized) {
                                if s.effort != level { pendingEffortSwitch = level; showEffortRestartConfirm = true }
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    }
                }

                // Mode toggle — mirrors web #mode-toggle (two-line: value + "MODE" label)
                Button { cycleInputMode() } label: {
                    VStack(spacing: 0) {
                        Text(vm.typingMode ? "TEXT" : "VOICE")
                            .font(.system(size: 8, weight: .semibold))
                            .tracking(0.5)
                        Text("MODE")
                            .font(.system(size: 7, weight: .medium))
                            .tracking(0.5)
                            .opacity(0.7)
                    }
                    .foregroundStyle(Color.cTextSec)
                    .lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color.glass, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.glassBorder, lineWidth: 0.5))
                    .fixedSize()
                }
            }

            Spacer()

            // Usage bar pill — mirrors web #usage-bar (ctx / 5h / 7d). Tap opens Settings.
            let hasUsage = vm.contextPct != nil || vm.usage5hPct != nil || vm.usage7dPct != nil
            if hasUsage {
                Button { vm.showSettings = true } label: {
                    HStack(spacing: 6) {
                        if let pct = vm.contextPct {
                            HStack(spacing: 2) {
                                Text("ctx:").foregroundStyle(Color.cTextTer)
                                Text("\(pct)%").foregroundStyle(usageColor(pct)).fontWeight(.semibold)
                            }
                        }
                        if let pct = vm.usage5hPct {
                            HStack(spacing: 2) {
                                Text("5h:").foregroundStyle(Color.cTextTer)
                                Text("\(pct)%").foregroundStyle(usageColor(pct)).fontWeight(.semibold)
                            }
                        }
                        if let pct = vm.usage7dPct {
                            HStack(spacing: 2) {
                                Text("7d:").foregroundStyle(Color.cTextTer)
                                Text("\(pct)%").foregroundStyle(usageColor(pct)).fontWeight(.semibold)
                            }
                        }
                    }
                    .font(.system(size: 9, weight: .medium))  // mobile web: font-size 0.72rem ≈ 9pt
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.glass, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.glassBorder, lineWidth: 0.5))
                }
                .fixedSize() // prevent SwiftUI from compressing the usage pill
            }

            // Connection dot only — mobile web hides #conn-label text and #focus-link
            let dotColor: Color = vm.isConnected ? .cSuccess : vm.isConnecting ? .cCaution : .cDanger
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .scaleEffect(vm.isConnecting && isPulsing ? 1.15 : vm.isConnecting ? 0.7 : 1.0)
                .opacity(vm.isConnecting && isPulsing ? 1.0 : vm.isConnecting ? 0.15 : 1.0)
                .animation(vm.isConnecting ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: isPulsing)
                .padding(6)
                .background(Color.glass, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.glassBorder, lineWidth: 0.5))
        }
        .padding(.horizontal, 12).padding(.vertical, 5)  // mobile web: padding 3px 12px
        .background {
            if #available(iOS 26, *) {
                Color.clear.glassEffect(.regular, in: TopOpenRect()).ignoresSafeArea(edges: .top)
            } else {
                Color.canvas1.opacity(0.85).background(.ultraThinMaterial).ignoresSafeArea(edges: .top)
            }
        }
    }

    private func modelName(_ m: String) -> String {
        switch m { case "sonnet": "Sonnet"; case "haiku": "Haiku"; default: "Opus" }
    }

    // MARK: - Chat Scroll Area

    private var chatScrollArea: some View {
        ChatScrollAreaView(
            vm: vm,
            isAtBottom: $isAtBottom,
            isLoadingOlder: $isLoadingOlder,
            thinkingExpanded: $thinkingExpanded,
            expandedAgentMsgIds: $expandedAgentMsgIds,
            isPulsing: $isPulsing,
            showCopiedToast: $showCopiedToast
        )
    }


    // MARK: - Bottom Input Area

    @ViewBuilder
    private var bottomInputArea: some View {
        Group {
            if vm.typingMode {
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
                    .disabled(vm.isProcessing || (vm.micMuted && !vm.isPlaying && !vm.isRecording))
                    .opacity(vm.isProcessing || (vm.micMuted && !vm.isPlaying) ? 0.45 : 1)

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
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 16)
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
                .onSubmit { vm.sendText() }.submitLabel(.send)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button {
                            UIApplication.shared.sendAction(
                                #selector(UIResponder.resignFirstResponder),
                                to: nil, from: nil, for: nil)
                        } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .foregroundStyle(Color.primary)
                        }
                    }
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
                            .onSubmit { vm.sendPreviewText() }.submitLabel(.send)
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
        // Mirrors web drawWaveform: voice color, opacity 0.35+level*0.65, bars 4px w / 2px gap
        let waveColor = vm.activeSession.map { voiceColor($0.voice) } ?? Color.cAccent
        return HStack(alignment: .center, spacing: 2) {
            ForEach(Array(vm.audioLevels.enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(waveColor.opacity(0.35 + Double(level) * 0.65))
                    .frame(width: 4, height: max(2, level * 8))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
        .frame(height: 12).frame(maxWidth: 240).clipped()
        .padding(.horizontal, 20).padding(.vertical, 4)
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
        if vm.isProcessing{ return Color(hex: 0x8E8E93) }
        if vm.micMuted    { return .cDanger }
        return Color(hex: 0x2563EB)  // blue matching user bubble
    }

    // MARK: - Helpers

    private var statusColor: Color {
        if vm.isRecording { return .cSuccess }   // green: recording (web: var(--green))
        if vm.isPlaying   { return .cWarning }   // orange: interruptable (web: var(--orange))
        return .cTextSec                          // default: processing/thinking (web: text-tertiary default)
    }

    private func cycleInputMode() { vm.inputMode = vm.typingMode ? "auto" : "typing" }

    private func effortIcon(_ e: String) -> String {
        switch e { case "low": "battery.25"; case "high": "bolt.fill"; default: "gauge.medium" }
    }
}


struct DebugView: View {
    @ObservedObject var vm: ClawMuxViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Debug").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text(vm.debugLastUpdated).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                }
                debugSection("Hub") {
                    debugKV("Port",    "\(vm.debugHub.port)")
                    debugKV("Uptime",  formatDuration(vm.debugHub.uptimeSeconds))
                    debugKV("Browser", vm.debugHub.browserConnected ? "connected" : "disconnected",
                            badge: vm.debugHub.browserConnected ? .up : .down)
                    debugKV("Sessions", "\(vm.debugHub.sessionCount)")
                }
                debugSection("Services") {
                    if vm.debugServices.isEmpty {
                        Text("Loading…").font(.caption).foregroundStyle(Theme.textTertiary)
                    } else {
                        ForEach(vm.debugServices) { svc in
                            HStack(spacing: 8) {
                                Text(svc.name).font(.system(size: 12, weight: .medium)).frame(width: 60, alignment: .leading)
                                debugBadge(svc.status, style: svc.status == "up" ? .up : .down)
                                Text(svc.detail).font(.system(size: 10)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                                Spacer()
                            }
                        }
                    }
                }
                debugSection("Hub Sessions") {
                    if vm.debugSessions.isEmpty {
                        Text("No active sessions").font(.caption).foregroundStyle(Theme.textTertiary)
                    } else {
                        ForEach(vm.debugSessions) { s in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(s.sessionId).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                                    debugBadge(s.state, style: s.state == "ready" ? .up : .starting)
                                    debugBadge(s.mcpConnected ? "mcp" : "no mcp", style: s.mcpConnected ? .up : .down)
                                }
                                HStack(spacing: 12) {
                                    Text(s.voice).font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                                    Text("idle \(formatDuration(s.idleSeconds))").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                                    Text("age \(formatDuration(s.ageSeconds))").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                debugSection("tmux Sessions") {
                    if vm.debugTmux.isEmpty {
                        Text("No tmux sessions").font(.caption).foregroundStyle(Theme.textTertiary)
                    } else {
                        ForEach(vm.debugTmux) { t in
                            HStack(spacing: 8) {
                                Text(t.name).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                                debugBadge(t.isVoice ? "voice" : "other", style: t.isVoice ? .starting : .down)
                                Text("\(t.windows)w").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                                Text(t.created).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                                Spacer()
                            }
                        }
                    }
                }
                debugSection("Hub Log") {
                    ScrollView {
                        Text(vm.debugLog.joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 300)
                    .padding(8)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { vm.stopDebugRefresh() }
    }

    enum BadgeStyle { case up, down, starting }

    @ViewBuilder
    private func debugSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.blue)
            content()
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgSecondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func debugKV(_ key: String, _ value: String, badge: BadgeStyle? = nil) -> some View {
        HStack(spacing: 8) {
            Text(key).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).frame(width: 80, alignment: .leading)
            if let badge { debugBadge(value, style: badge) } else { Text(value).font(.system(size: 12)).foregroundStyle(Theme.textPrimary) }
            Spacer()
        }
    }

    @ViewBuilder
    private func debugBadge(_ text: String, style: BadgeStyle) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(badgeBg(style), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .foregroundStyle(badgeFg(style))
    }

    private func badgeBg(_ s: BadgeStyle) -> Color {
        switch s { case .up: Theme.green.opacity(0.15); case .down: Theme.red.opacity(0.15); case .starting: Theme.yellow.opacity(0.12) }
    }
    private func badgeFg(_ s: BadgeStyle) -> Color {
        switch s { case .up: Theme.green; case .down: Theme.red; case .starting: Theme.yellow }
    }
}
