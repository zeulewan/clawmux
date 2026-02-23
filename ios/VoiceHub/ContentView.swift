import SwiftUI

// MARK: - Adaptive Theme Colors

private enum Theme {
    // Backgrounds
    static let bg = Color(.systemBackground)
    static let bgSecondary = Color(.secondarySystemBackground)
    static let bgTertiary = Color(.tertiarySystemBackground)
    static let bgGrouped = Color(.systemGroupedBackground)

    // Card
    static let card = Color(.secondarySystemGroupedBackground)
    static let cardBorder = Color(.separator)

    // Text
    static let textPrimary = Color(.label)
    static let textSecondary = Color(.secondaryLabel)
    static let textTertiary = Color(.tertiaryLabel)

    // Accents (Apple HIG system colors - work in both modes)
    static let blue = Color(.systemBlue)
    static let green = Color(.systemGreen)
    static let red = Color(.systemRed)
    static let orange = Color(.systemOrange)
    static let yellow = Color(.systemYellow)
    static let gray = Color(.systemGray)
    static let gray3 = Color(.systemGray3)
    static let gray5 = Color(.systemGray5)
}

struct ContentView: View {
    @StateObject private var vm = VoiceHubViewModel()
    @State private var isPulsing = false
    @State private var resetVoiceId: String?
    @State private var showResetConfirm = false
    @State private var pttDragOffset: CGFloat = 0
    @State private var pttDragOffsetY: CGFloat = 0
    @State private var pttGestureCommitted = false
    @State private var sidebarExpanded = false

    var body: some View {
        ZStack(alignment: .leading) {
            // Main content area
            VStack(spacing: 0) {
                headerBar
                if vm.showDebug {
                    DebugView(vm: vm)
                } else if vm.activeSessionId != nil {
                    chatArea
                    bottomControls
                } else {
                    emptyStateView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, 56)

            // Scrim overlay
            if sidebarExpanded {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.2)) { sidebarExpanded = false }
                    }
                    .zIndex(5)
            }

            // Sidebar
            sidebarView
                .frame(width: sidebarExpanded ? 200 : 56)
                .frame(maxHeight: .infinity)
                .background(Theme.bgSecondary.ignoresSafeArea())
                .shadow(color: sidebarExpanded ? .black.opacity(0.2) : .clear, radius: 12, x: 4)
                .zIndex(10)
        }
        .background(Theme.bg.ignoresSafeArea())
        .animation(.spring(response: 0.25, dampingFraction: 0.88), value: sidebarExpanded)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: vm.showDebug)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: vm.activeSessionId)
        .animation(.easeInOut(duration: 0.18), value: vm.typingMode)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: vm.showPTTTextField)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: vm.showTranscriptPreview)
        .sheet(isPresented: $vm.showSettings) {
            SettingsView(vm: vm)
        }
        .onOpenURL { url in
            vm.handleOpenURL(url)
        }
        .alert("Error", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .alert("Reset History", isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) {
                if let vid = resetVoiceId {
                    vm.resetHistory(voiceId: vid)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let name = ALL_VOICES.first { $0.id == resetVoiceId }?.name ?? "this voice"
            Text("Clear all history for \(name)? This also ends the active session.")
        }
    }

    // MARK: - Sidebar

    private var sidebarView: some View {
        VStack(spacing: 0) {
            // Top: connection dot
            HStack(spacing: 0) {
                Circle()
                    .fill(connectionDotColor)
                    .frame(width: 8, height: 8)
                    .frame(width: 56)
                if sidebarExpanded {
                    Text(vm.isConnected ? "Connected" : vm.isConnecting ? "Connecting" : "Offline")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(connectionDotColor)
                        .transition(.opacity)
                    Spacer()
                }
            }
            .padding(.vertical, 10)

            Divider().padding(.horizontal, 8)

            // Voice icons
            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(ALL_VOICES) { voice in
                        sidebarRow(voice)
                    }
                }
                .padding(.vertical, 6)
            }

            Spacer(minLength: 0)

            Divider().padding(.horizontal, 8)

            // Expand / collapse toggle
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.88)) {
                    sidebarExpanded.toggle()
                }
            } label: {
                HStack(spacing: 0) {
                    Image(systemName: sidebarExpanded ? "chevron.left" : "line.3.horizontal")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 56, height: 36)
                    if sidebarExpanded {
                        Text("Collapse")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                            .transition(.opacity)
                        Spacer()
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func sidebarRow(_ voice: VoiceInfo) -> some View {
        let activeForVoice = vm.sessions.first { $0.voice == voice.id }
        let isSpawning = vm.spawningVoiceIds.contains(voice.id)
        let isSelected = vm.activeSession?.voice == voice.id
        let color = voiceColor(voice.id)
        let ringColor = sidebarRingColor(active: activeForVoice, spawning: isSpawning)
        let isAlive = activeForVoice != nil || isSpawning

        let hasUnread = (activeForVoice?.unreadCount ?? 0) > 0

        // Icon column — always 56px, icon never moves
        let iconView = ZStack(alignment: .topTrailing) {
            ZStack {
                Circle()
                    .fill(color.opacity(isAlive ? 0.18 : 0.08))
                    .frame(width: 36, height: 36)
                if isAlive {
                    Circle()
                        .strokeBorder(ringColor, lineWidth: 2)
                        .frame(width: 36, height: 36)
                }
                Image(systemName: voiceIconName(voice.id))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isAlive ? color : color.opacity(0.4))
            }
            if hasUnread {
                Circle()
                    .fill(Theme.red)
                    .frame(width: 10, height: 10)
                    .offset(x: 2, y: -2)
            }
        }

        // Label column — only rendered when expanded
        let labelView = VStack(alignment: .leading, spacing: 2) {
            Text(voice.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            HStack(spacing: 4) {
                Circle()
                    .fill(isAlive ? ringColor : Theme.gray3)
                    .frame(width: 5, height: 5)
                Text(sidebarStatusLabel(active: activeForVoice, spawning: isSpawning))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isAlive ? ringColor : Theme.textTertiary)
            }
            if let proj = activeForVoice?.project, !proj.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text(proj)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                    if let area = activeForVoice?.projectArea, !area.isEmpty {
                        Text(area)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.textTertiary.opacity(0.7))
                            .lineLimit(1)
                    }
                }
            }
        }

        return ZStack(alignment: .leading) {
            // Selected highlight background
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.blue.opacity(0.08))
                    .padding(.horizontal, 4)
            }

            // Content
            HStack(spacing: 0) {
                iconView
                    .frame(width: 56, height: 48)

                if sidebarExpanded {
                    labelView
                        .padding(.trailing, 10)
                        .opacity(sidebarExpanded ? 1 : 0)
                    Spacer(minLength: 0)
                }
            }

            // Selected accent pill — pinned to left edge
            if isSelected {
                UnevenRoundedRectangle(
                    topLeadingRadius: 0, bottomLeadingRadius: 0,
                    bottomTrailingRadius: 3, topTrailingRadius: 3
                )
                .fill(Theme.blue)
                .frame(width: 3, height: 28)
            }
        }
        .frame(height: 48)
        .contentShape(Rectangle())
        .onTapGesture {
            if sidebarExpanded {
                withAnimation(.easeOut(duration: 0.2)) { sidebarExpanded = false }
            }
            if let s = activeForVoice {
                vm.switchToSession(s.id)
            } else if !isSpawning {
                vm.spawnSession(voiceId: voice.id)
            }
        }
        .contextMenu {
            if let s = activeForVoice {
                Button(role: .destructive) {
                    vm.terminateSession(s.id)
                } label: {
                    Label("End Session", systemImage: "xmark.circle")
                }
            }
            Button(role: .destructive) {
                resetVoiceId = voice.id
                showResetConfirm = true
            } label: {
                Label("Reset History", systemImage: "trash")
            }
        }
    }

    private func sidebarRingColor(active: VoiceSession?, spawning: Bool) -> Color {
        if spawning { return Theme.yellow }
        guard let s = active else { return Theme.gray3 }
        if s.status == .starting { return Theme.yellow }
        if s.unreadCount > 0 { return Theme.red }
        if s.isThinking { return Theme.orange }
        let st = s.statusText
        if st == "Speaking..." || st == "Playing..." { return Theme.blue }
        return Theme.green
    }

    private func sidebarStatusLabel(active: VoiceSession?, spawning: Bool) -> String {
        if spawning { return "Starting..." }
        guard let s = active else { return "Offline" }
        if s.status == .starting { return "Starting..." }
        if s.isThinking { return "Thinking..." }
        let st = s.statusText
        if s.unreadCount > 1 { return "\(s.unreadCount) New Messages" }
        if s.unreadCount == 1 { return "1 New Message" }
        if st == "Speaking..." || st == "Playing..." { return "Speaking" }
        return "Idle"
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44))
                .foregroundStyle(Theme.textTertiary.opacity(0.5))
            VStack(spacing: 6) {
                Text("Voice Hub")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Tap a voice to start a session")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            if vm.showDebug {
                Button {
                    vm.showDebug = false
                    vm.stopDebugRefresh()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(vm.showDebug ? "Debug" : vm.activeSession?.label ?? "Voice Hub")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let proj = vm.activeSession?.project, !proj.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(proj)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                        if let area = vm.activeSession?.projectArea, !area.isEmpty {
                            Text(area)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.textTertiary.opacity(0.7))
                                .lineLimit(1)
                        }
                    }
                }
            }

            Spacer()

            // Usage stats (compact)
            if vm.usage5hPct != nil || vm.usage7dPct != nil {
                VStack(alignment: .trailing, spacing: 1) {
                    if let pct = vm.usage5hPct {
                        HStack(spacing: 3) {
                            Text("5h")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(Theme.textTertiary)
                            Text("\(pct)%")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(usageColor(pct))
                        }
                    }
                    if let pct = vm.usage7dPct {
                        HStack(spacing: 3) {
                            Text("7d")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(Theme.textTertiary)
                            Text("\(pct)%")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(usageColor(pct))
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            // Mic mute (auto mode, in session)
            if vm.activeSessionId != nil && vm.isAutoMode {
                Button { vm.micMuted.toggle() } label: {
                    Image(systemName: vm.micMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(vm.micMuted ? Theme.red : Theme.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }

            // Settings
            Button { vm.showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 30, height: 30)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func voiceIconName(_ voiceId: String) -> String {
        switch voiceId {
        case "af_sky": return "cloud.fill"
        case "af_alloy": return "diamond.fill"
        case "af_sarah": return "heart.fill"
        case "am_adam": return "leaf.fill"
        case "am_echo": return "waveform"
        case "am_onyx": return "shield.fill"
        case "bm_fable": return "book.fill"
        default: return "person.fill"
        }
    }

    // MARK: - Bottom Controls

    @ViewBuilder
    private var bottomControls: some View {
        if vm.typingMode {
            textInputBar
                .transition(.opacity)
        } else if vm.pushToTalk && vm.showPTTTextField {
            pttTextInputBar
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            controlsOverlay
                .transition(.opacity)
        }
    }

    private var statusColor: Color {
        if vm.isRecording { return Theme.red }
        if vm.isPlaying { return Theme.blue }
        if vm.isProcessing { return Theme.orange }
        if vm.activeSession?.isThinking == true { return Theme.orange }
        return Theme.green
    }

    private var connectionDotColor: Color {
        if vm.isConnected { return Theme.green }
        if vm.isConnecting { return Theme.yellow }
        return Theme.red
    }

    // MARK: - Chat Area

    private var chatArea: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        // Push content to bottom when there are few messages
                        Spacer(minLength: 0)
                            .frame(maxHeight: .infinity)

                        ForEach(vm.activeMessages) { msg in
                            chatBubble(msg)
                                .id(msg.id)
                        }
                        if vm.activeSession?.isThinking == true {
                            thinkingIndicator
                                .id("thinking")
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                    .frame(minHeight: geo.size.height)
                    .id("content")
                }
                .defaultScrollAnchor(.bottom)
                .id(vm.activeSessionId ?? "none")
                .onChange(of: vm.activeMessages.count) { _, _ in
                    scrollToBottom(proxy, to: "content")
                }
                .onChange(of: vm.activeSession?.isThinking) { _, _ in
                    scrollToBottom(proxy, to: "content")
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, to id: String = "content") {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }

    private func chatBubble(_ msg: ChatMessage) -> some View {
        HStack {
            if msg.role == "user" { Spacer(minLength: 30) }
            if msg.role == "system" { Spacer() }

            Text(msg.text)
                .font(msg.role == "system" ? .caption : .system(size: 14))
                .lineSpacing(2)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .foregroundStyle(bubbleForeground(msg.role))
                .background(bubbleBackground(msg.role), in: bubbleShape)

            if msg.role == "assistant" { Spacer(minLength: 30) }
            if msg.role == "system" { Spacer() }
        }
    }

    private var bubbleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    private func bubbleBackground(_ role: String) -> some ShapeStyle {
        switch role {
        case "user":
            return AnyShapeStyle(Theme.blue)
        case "assistant":
            if let voice = vm.activeSession?.voice {
                return AnyShapeStyle(voiceColor(voice).opacity(0.12))
            }
            return AnyShapeStyle(Theme.bgSecondary)
        default:
            return AnyShapeStyle(Color.clear)
        }
    }

    private func bubbleForeground(_ role: String) -> Color {
        switch role {
        case "user": .white
        case "system": Theme.textTertiary
        default: Theme.textPrimary
        }
    }

    private var thinkingIndicator: some View {
        let color = vm.activeSession.flatMap { voiceColor($0.voice) } ?? Theme.textTertiary

        return HStack {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(color.opacity(0.6))
                        .frame(width: 7, height: 7)
                        .offset(y: isPulsing ? -4 : 4)
                        .animation(
                            .easeInOut(duration: 0.5)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.15),
                            value: isPulsing
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onAppear { isPulsing = true }
            .onDisappear { isPulsing = false }
            Spacer(minLength: 40)
        }
    }

    // MARK: - Floating Controls

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            LinearGradient(
                stops: [
                    .init(color: Theme.bg.opacity(0), location: 0),
                    .init(color: Theme.bg, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 28)
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                if vm.isRecording {
                    waveformView
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                if vm.showTranscriptPreview {
                    HStack(spacing: 8) {
                        Button { vm.clearTranscriptPreview() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(width: 24, height: 24)
                                .background(.ultraThinMaterial, in: Circle())
                        }

                        Group {
                            if vm.isTranscribingPreview {
                                HStack(spacing: 6) {
                                    ProgressView().scaleEffect(0.7)
                                    Text("Transcribing...")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            } else if let error = vm.pttTranscriptionError {
                                Text(error)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.orange)
                            } else {
                                Text(vm.transcriptPreviewText)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(3)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.bgSecondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .onTapGesture {
                            if vm.pushToTalk { vm.tapTranscriptToEdit() }
                        }

                        if vm.pushToTalk {
                            Button { vm.sendTranscriptPreview() } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(
                                        vm.transcriptPreviewText.isEmpty || vm.isTranscribingPreview
                                            ? Theme.gray3 : Theme.blue
                                    )
                            }
                            .disabled(vm.transcriptPreviewText.isEmpty || vm.isTranscribingPreview)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                HStack(alignment: .center) {
                    if vm.isRecording && !vm.pushToTalk {
                        Button { vm.cancelRecording() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Theme.red)
                                .frame(width: 40, height: 40)
                                .background(Theme.red.opacity(0.12), in: Circle())
                        }
                        .transition(.scale.combined(with: .opacity))
                    } else if vm.isRecording && vm.pushToTalk {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .bold))
                            Text("Cancel")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(pttDragOffset < -80 ? Theme.red : Theme.textTertiary)
                        .opacity(pttDragOffset < -10 ? min(1.0, Double(-pttDragOffset - 10) / 60.0) : 0.3)
                        .frame(width: 60)
                        .transition(.opacity)
                    } else {
                        Color.clear.frame(width: 60, height: 40)
                    }

                    Spacer()

                    Group {
                        if vm.pushToTalk {
                            micButtonVisual
                                .contentShape(Circle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            if vm.showPTTTextField || vm.showTranscriptPreview { return }
                                            if pttGestureCommitted { return }

                                            let dx = value.translation.width
                                            let dy = value.translation.height

                                            if dy < -60 && abs(dx) < 40 && vm.isRecording {
                                                pttGestureCommitted = true
                                                vm.pttSwipeUpSend()
                                                return
                                            }
                                            if dx < -80 && abs(dy) < 40 && vm.isRecording {
                                                pttGestureCommitted = true
                                                vm.cancelRecording()
                                                return
                                            }
                                            if dx > 60 && abs(dy) < 40 {
                                                pttGestureCommitted = true
                                                vm.enterPTTTextMode()
                                                return
                                            }

                                            vm.pttPressed()
                                            if vm.isRecording {
                                                pttDragOffset = dx
                                                pttDragOffsetY = dy
                                            }
                                        }
                                        .onEnded { _ in
                                            if !pttGestureCommitted && !vm.showPTTTextField {
                                                if vm.isRecording {
                                                    vm.pttReleasedForPreview()
                                                } else {
                                                    vm.pttReleased()
                                                }
                                            } else if !pttGestureCommitted {
                                                vm.pttReleased()
                                            }
                                            pttDragOffset = 0
                                            pttDragOffsetY = 0
                                            pttGestureCommitted = false
                                        }
                                )
                        } else {
                            Button(action: vm.micAction) {
                                micButtonVisual
                            }
                        }
                    }
                    .disabled(vm.isProcessing || vm.recordBlockedByThinking || (vm.micMuted && !vm.isPlaying && !vm.isRecording))
                    .opacity(vm.isProcessing || vm.recordBlockedByThinking || (vm.micMuted && !vm.isPlaying) ? 0.5 : 1.0)

                    Spacer()

                    if vm.isRecording && vm.pushToTalk {
                        HStack(spacing: 4) {
                            Text("Aa")
                                .font(.system(size: 12, weight: .semibold))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(pttDragOffset > 40 ? Theme.blue : Theme.textTertiary)
                        .opacity(pttDragOffset > 10 ? min(1.0, Double(pttDragOffset - 10) / 50.0) : 0.3)
                        .frame(width: 60)
                        .transition(.opacity)
                    } else {
                        Color.clear.frame(width: 60, height: 40)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)

                bottomStatusBar
                    .padding(.top, 12)
            }
            .padding(.bottom, 4)
            .background(Theme.bg)
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Text Input Bar

    private var textInputBar: some View {
        VStack(spacing: 0) {
            LinearGradient(
                stops: [
                    .init(color: Theme.bg.opacity(0), location: 0),
                    .init(color: Theme.bg, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 28)
            .allowsHitTesting(false)

            VStack(spacing: 6) {
                bottomStatusBar

                HStack(spacing: 10) {
                    TextField("Message", text: $vm.typingText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                        .lineLimit(1...5)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.bgSecondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .onSubmit { vm.sendText() }
                        .submitLabel(.send)

                    Button {
                        vm.sendText()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(
                                vm.typingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? Theme.gray3 : Theme.blue
                            )
                    }
                    .disabled(vm.typingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
            .background(Theme.bg)
        }
        .padding(.horizontal, 8)
    }

    // MARK: - PTT Text Input Bar

    @FocusState private var pttTextFieldFocused: Bool

    private var pttTextInputBar: some View {
        VStack(spacing: 0) {
            LinearGradient(
                stops: [
                    .init(color: Theme.bg.opacity(0), location: 0),
                    .init(color: Theme.bg, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 28)
            .allowsHitTesting(false)

            VStack(spacing: 6) {
                bottomStatusBar

                if vm.isRecording {
                    waveformView
                }

                HStack(spacing: 10) {
                    Button { vm.dismissPTTTextField() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial, in: Circle())
                    }

                    Button {
                        if vm.isRecording {
                            vm.stopRecording()
                        } else {
                            vm.startRecording()
                        }
                    } label: {
                        Image(systemName: vm.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(vm.isRecording ? Theme.red : Theme.blue)
                    }
                    .disabled(vm.isTranscribing)

                    if vm.isTranscribing {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Edit message...", text: $vm.pttPreviewText, axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(.subheadline)
                                .lineLimit(1...5)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Theme.bgSecondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .focused($pttTextFieldFocused)
                                .onSubmit { vm.sendPreviewText() }
                                .submitLabel(.send)
                            if let error = vm.pttTranscriptionError {
                                Text(error)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.textTertiary)
                                    .padding(.horizontal, 12)
                            }
                        }
                    }

                    Button { vm.sendPreviewText() } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(
                                vm.pttPreviewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? Theme.gray3 : Theme.blue
                            )
                    }
                    .disabled(vm.pttPreviewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isTranscribing)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
            .background(Theme.bg)
        }
        .padding(.horizontal, 8)
        .onAppear { pttTextFieldFocused = true }
    }

    // MARK: - Waveform

    private var waveformView: some View {
        let color = vm.activeSession.flatMap { voiceColor($0.voice) } ?? Theme.green
        return HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(vm.audioLevels.enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color.opacity(0.5 + Double(level) * 0.5))
                    .frame(width: 3, height: max(3, level * 28))
            }
        }
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Mic Helpers

    private var micButtonVisual: some View {
        ZStack {
            if vm.isRecording && !vm.pushToTalk {
                Circle()
                    .fill(Theme.green.opacity(0.15))
                    .frame(width: 80, height: 80)
                    .scaleEffect(isPulsing ? 1.15 : 1.0)
                    .animation(
                        .easeInOut(duration: 1.0).repeatForever(),
                        value: isPulsing
                    )
            }

            Circle()
                .fill(micColor)
                .frame(width: 64, height: 64)
                .shadow(color: micColor.opacity(0.3), radius: 16, y: 4)

            Image(systemName: micIcon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var micIcon: String {
        if vm.isPlaying { return "hand.raised.fill" }
        if vm.isRecording { return "arrow.up.circle.fill" }
        if vm.micMuted { return "mic.slash.fill" }
        return "mic.fill"
    }

    private var micColor: Color {
        if vm.isPlaying { return Theme.orange }
        if vm.isRecording { return Theme.green }
        if vm.isProcessing { return Theme.gray }
        if vm.micMuted { return Theme.red }
        return Theme.blue
    }

    // MARK: - Bottom Status Bar

    private var bottomStatusBar: some View {
        HStack(spacing: 8) {
            Button { cycleInputMode() } label: {
                Text(modeLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.bgSecondary, in: Capsule())
            }

            if !vm.statusText.isEmpty {
                Text(vm.statusText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.12), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var modeLabel: String {
        switch vm.inputMode {
        case "auto": return "Auto"
        case "ptt": return "PTT"
        default: return "Typing"
        }
    }

    private func cycleInputMode() {
        let modes = ["auto", "ptt", "typing"]
        if let idx = modes.firstIndex(of: vm.inputMode) {
            vm.inputMode = modes[(idx + 1) % modes.count]
        }
    }

    // MARK: - Voice Colors

    private func voiceColor(_ voiceId: String) -> Color {
        switch voiceId {
        case "af_sky": return Color(hex: 0x3A86FF)
        case "af_alloy": return Color(hex: 0xE67E22)
        case "af_sarah": return Color(hex: 0xE63946)
        case "am_adam": return Color(hex: 0x2ECC71)
        case "am_echo": return Color(hex: 0x9B59B6)
        case "am_onyx": return Color(hex: 0x7F8C8D)
        case "bm_fable": return Color(hex: 0xF1C40F)
        default: return Color(.systemGray3)
        }
    }

    private func usageColor(_ pct: Int) -> Color {
        if pct >= 80 { return Theme.red }
        if pct >= 60 { return Theme.orange }
        if pct >= 40 { return Theme.yellow }
        return Theme.green
    }
}

// MARK: - Debug View

struct DebugView: View {
    @ObservedObject var vm: VoiceHubViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Debug")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text(vm.debugLastUpdated)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }

                debugSection("Hub") {
                    debugKV("Port", "\(vm.debugHub.port)")
                    debugKV("Uptime", formatDuration(vm.debugHub.uptimeSeconds))
                    debugKV(
                        "Browser", vm.debugHub.browserConnected ? "connected" : "disconnected",
                        badge: vm.debugHub.browserConnected ? .up : .down)
                    debugKV("Sessions", "\(vm.debugHub.sessionCount)")
                }

                debugSection("Services") {
                    if vm.debugServices.isEmpty {
                        Text("Loading...")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    } else {
                        ForEach(vm.debugServices) { svc in
                            HStack(spacing: 8) {
                                Text(svc.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(width: 60, alignment: .leading)
                                debugBadge(svc.status, style: svc.status == "up" ? .up : .down)
                                Text(svc.detail)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                                Spacer()
                            }
                        }
                    }
                }

                debugSection("Hub Sessions") {
                    if vm.debugSessions.isEmpty {
                        Text("No active sessions")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    } else {
                        ForEach(vm.debugSessions) { s in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(s.sessionId)
                                        .font(.system(size: 11, design: .monospaced))
                                        .lineLimit(1)
                                    debugBadge(
                                        s.status,
                                        style: s.status == "ready" ? .up : .starting)
                                    debugBadge(
                                        s.mcpConnected ? "mcp" : "no mcp",
                                        style: s.mcpConnected ? .up : .down)
                                }
                                HStack(spacing: 12) {
                                    Text(s.voice)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.textSecondary)
                                    Text("idle \(formatDuration(s.idleSeconds))")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.textTertiary)
                                    Text("age \(formatDuration(s.ageSeconds))")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                debugSection("tmux Sessions") {
                    if vm.debugTmux.isEmpty {
                        Text("No tmux sessions")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    } else {
                        ForEach(vm.debugTmux) { t in
                            HStack(spacing: 8) {
                                Text(t.name)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                debugBadge(
                                    t.isVoice ? "voice" : "other",
                                    style: t.isVoice ? .starting : .down)
                                Text("\(t.windows)w")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.textTertiary)
                                Text(t.created)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.textTertiary)
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
        .onDisappear {
            vm.stopDebugRefresh()
        }
    }

    enum BadgeStyle { case up, down, starting }

    @ViewBuilder
    private func debugSection<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.blue)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgSecondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func debugKV(_ key: String, _ value: String, badge: BadgeStyle? = nil) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 80, alignment: .leading)
            if let badge {
                debugBadge(value, style: badge)
            } else {
                Text(value)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func debugBadge(_ text: String, style: BadgeStyle) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeBg(style), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .foregroundStyle(badgeFg(style))
    }

    private func badgeBg(_ style: BadgeStyle) -> Color {
        switch style {
        case .up: Theme.green.opacity(0.15)
        case .down: Theme.red.opacity(0.15)
        case .starting: Theme.yellow.opacity(0.12)
        }
    }

    private func badgeFg(_ style: BadgeStyle) -> Color {
        switch style {
        case .up: Theme.green
        case .down: Theme.red
        case .starting: Theme.yellow
        }
    }
}

// MARK: - Settings Root

struct SettingsView: View {
    @ObservedObject var vm: VoiceHubViewModel
    @Environment(\.dismiss) var dismiss
    @State private var draftURL: String = ""

    var urlChanged: Bool { draftURL.trimmingCharacters(in: .whitespaces) != vm.serverURL.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Server URL", text: $draftURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    if vm.isConnected && !urlChanged {
                        HStack(spacing: 6) {
                            Circle().fill(Color(.systemGreen)).frame(width: 8, height: 8)
                            Text("Connected")
                                .font(.subheadline)
                                .foregroundStyle(Color(.systemGreen))
                        }
                    } else {
                        Button("Connect") {
                            vm.serverURL = draftURL.trimmingCharacters(in: .whitespaces)
                            vm.connect()
                            dismiss()
                        }
                        .disabled(draftURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    Text("e.g. workstation.tailee9084.ts.net:3460")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .onAppear { draftURL = vm.serverURL }

                Section("Model") {
                    Picker("Claude Model", selection: $vm.selectedModel) {
                        Text("Opus").tag("opus")
                        Text("Sonnet").tag("sonnet")
                        Text("Haiku").tag("haiku")
                    }
                    .onChange(of: vm.selectedModel) { _, v in vm.updateSetting("model", value: v) }
                    Text("Applies to newly spawned sessions only.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if vm.activeSessionId != nil {
                    Section("Active Session") {
                        Picker("Voice", selection: Binding(
                            get: { vm.activeVoice }, set: { vm.activeVoice = $0 }
                        )) {
                            ForEach(ALL_VOICES) { v in Text(v.name).tag(v.id) }
                        }
                        Picker("Speed", selection: Binding(
                            get: { vm.activeSpeed }, set: { vm.activeSpeed = $0 }
                        )) {
                            ForEach(SPEED_OPTIONS, id: \.value) { Text($0.label).tag($0.value) }
                        }
                    }
                }

                Section("Mode Settings") {
                    NavigationLink {
                        AutoModeSettingsView(vm: vm)
                    } label: {
                        Label("Auto", systemImage: "waveform")
                    }
                    NavigationLink {
                        PTTModeSettingsView(vm: vm)
                    } label: {
                        Label("Push to Talk", systemImage: "hand.tap")
                    }
                    NavigationLink {
                        TypingModeSettingsView(vm: vm)
                    } label: {
                        Label("Typing", systemImage: "keyboard")
                    }
                }

                Section {
                    Toggle("Background Mode", isOn: $vm.backgroundMode)
                } header: {
                    Text("Background")
                } footer: {
                    Text(
                        vm.backgroundMode
                            ? "Voice sessions stay alive when the app is backgrounded using a silent audio loop."
                            : "The WebSocket connection may drop when the app is backgrounded."
                    )
                }

                if vm.usage5hPct != nil || vm.usage7dPct != nil {
                    Section("Usage") {
                        if let pct = vm.usage5hPct {
                            HStack {
                                Text("5-hour window")
                                Spacer()
                                VStack(alignment: .trailing) {
                                    Text("\(pct)%")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(pct >= 80 ? Color(.systemRed) : pct >= 60 ? Color(.systemOrange) : Color(.systemGreen))
                                    if let reset = vm.usage5hReset {
                                        Text("resets in \(reset)")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                        if let pct = vm.usage7dPct {
                            HStack {
                                Text("7-day window")
                                Spacer()
                                VStack(alignment: .trailing) {
                                    Text("\(pct)%")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(pct >= 80 ? Color(.systemRed) : pct >= 60 ? Color(.systemOrange) : Color(.systemGreen))
                                    if let reset = vm.usage7dReset {
                                        Text("resets in \(reset)")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                        Button {
                            let gen = UIImpactFeedbackGenerator(style: .light)
                            gen.impactOccurred()
                            vm.fetchUsage()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                }

                Section("Debug") {
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            vm.showDebug = true
                            vm.startDebugRefresh()
                        }
                    } label: {
                        Label("Open Debug Panel", systemImage: "ant")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Auto Mode Settings

struct AutoModeSettingsView: View {
    @ObservedObject var vm: VoiceHubViewModel

    var body: some View {
        Form {
            Section {
                Toggle("Auto Record", isOn: $vm.autoRecord)
                    .onChange(of: vm.autoRecord) { _, v in vm.updateSetting("auto_record", value: v) }
                Toggle("Voice Detection (VAD)", isOn: $vm.vadEnabled)
                    .onChange(of: vm.vadEnabled) { _, v in vm.updateSetting("auto_end", value: v) }
                Toggle("Auto Interrupt", isOn: $vm.autoInterrupt)
                    .onChange(of: vm.autoInterrupt) { _, v in vm.updateSetting("auto_interrupt", value: v) }
                Toggle("Record While Thinking", isOn: $vm.allowRecordWhileThinking)
            } header: {
                Text("Input")
            } footer: {
                Text("Mic opens automatically after the agent speaks.")
            }

            if vm.vadEnabled {
                Section {
                    Picker("Stop After", selection: $vm.vadSilenceDuration) {
                        Text("0.5 s").tag(0.5)
                        Text("1 s").tag(1.0)
                        Text("1.5 s").tag(1.5)
                        Text("2 s").tag(2.0)
                        Text("3 s").tag(3.0)
                        Text("4 s").tag(4.0)
                        Text("5 s").tag(5.0)
                    }
                    Picker("Silence Cutoff", selection: $vm.vadThreshold) {
                        Text("Sensitive (quiet room)").tag(5.0)
                        Text("Normal").tag(10.0)
                        Text("Relaxed (noisy room)").tag(20.0)
                    }
                } header: {
                    Text("VAD Tuning")
                } footer: {
                    Text("Stop After: silence duration before auto-stopping. Silence Cutoff: how quiet the mic must be to count as silence.")
                }
            }

            Section("Sounds") {
                Toggle("Thinking", isOn: $vm.soundThinkingAuto)
                Toggle("Listening Cue", isOn: $vm.soundListeningAuto)
                Toggle("Processing Cue", isOn: $vm.soundProcessingAuto)
                Toggle("Session Ready", isOn: $vm.soundReadyAuto)
            }

            Section("Haptics") {
                Toggle("Recording Start / Stop", isOn: $vm.hapticsRecordingAuto)
                Toggle("Playback Start", isOn: $vm.hapticsPlaybackAuto)
                Toggle("Session Events", isOn: $vm.hapticsSessionAuto)
            }

            Section {
                Toggle("Notifications", isOn: $vm.notifyAuto)
            } footer: {
                Text("Notify when the agent responds while the app is in the background.")
            }

            Section {
                Toggle("Live Activity", isOn: $vm.liveActivityAuto)
            } footer: {
                Text("Show session status on Dynamic Island and Lock Screen.")
            }
        }
        .navigationTitle("Auto Mode")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - PTT Mode Settings

struct PTTModeSettingsView: View {
    @ObservedObject var vm: VoiceHubViewModel

    var body: some View {
        Form {
            Section {
                Toggle("Record While Thinking", isOn: $vm.allowRecordWhileThinking)
            } header: {
                Text("Input")
            } footer: {
                Text("Hold the mic button to record. Release to send. Slide left to cancel. Swipe right for text input.")
            }

            Section("Sounds") {
                Toggle("Thinking", isOn: $vm.soundThinkingPTT)
                Toggle("Session Ready", isOn: $vm.soundReadyPTT)
            }

            Section("Haptics") {
                Toggle("Recording Start / Stop", isOn: $vm.hapticsRecordingPTT)
                Toggle("Playback Start", isOn: $vm.hapticsPlaybackPTT)
                Toggle("Session Events", isOn: $vm.hapticsSessionPTT)
            }

            Section {
                Toggle("Notifications", isOn: $vm.notifyPTT)
            } footer: {
                Text("Notify when the agent responds while the app is in the background.")
            }

            Section {
                Toggle("Live Activity", isOn: $vm.liveActivityPTT)
            } footer: {
                Text("Show session status on Dynamic Island and Lock Screen.")
            }
        }
        .navigationTitle("Push to Talk")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Typing Mode Settings

struct TypingModeSettingsView: View {
    @ObservedObject var vm: VoiceHubViewModel

    var body: some View {
        Form {
            Section("Haptics") {
                Toggle("Send Message", isOn: $vm.hapticsSend)
                Toggle("Session Events", isOn: $vm.hapticsSessionTyping)
            }

            Section {
                Toggle("Notifications", isOn: $vm.notifyTyping)
            } footer: {
                Text("Notify when the agent responds while the app is in the background.")
            }

            Section {
                Text("No Live Activity in typing mode. Notifications are used instead.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .navigationTitle("Typing")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Color Hex

extension Color {
    init(hex: UInt) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
