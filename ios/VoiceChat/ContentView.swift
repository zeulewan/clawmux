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
    @StateObject private var vm = VoiceChatViewModel()
    @State private var isPulsing = false
    @State private var resetVoiceId: String?
    @State private var showResetConfirm = false
    @State private var pttDragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            if vm.showDebug {
                VStack(spacing: 0) {
                    headerBar
                    DebugView(vm: vm)
                }
                .transition(.opacity)
            } else if vm.activeSessionId != nil {
                sessionView
                    .transition(.asymmetric(
                        insertion: .push(from: .trailing),
                        removal: .push(from: .trailing)
                    ))
            } else {
                VStack(spacing: 0) {
                    headerBar
                    voiceGrid
                }
                .transition(.asymmetric(
                    insertion: .push(from: .leading),
                    removal: .push(from: .leading)
                ))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.92), value: vm.activeSessionId)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: vm.showDebug)
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

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            if vm.activeSession != nil {
                Button { vm.goHome() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }

            Text(vm.activeSession?.label ?? "Voice Hub")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            // Connection indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(connectionDotColor)
                    .frame(width: 7, height: 7)
                Text(connectionLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())

            Button {
                if vm.showDebug {
                    vm.stopDebugRefresh()
                    vm.goHome()
                } else {
                    vm.goHome()
                    vm.showDebug = true
                    vm.startDebugRefresh()
                }
            } label: {
                Image(systemName: "ant")
                    .font(.system(size: 14))
                    .foregroundStyle(vm.showDebug ? Theme.blue : Theme.textTertiary)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Button { vm.showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Voice Grid (Landing)

    private var voiceGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 14),
                    GridItem(.flexible(), spacing: 14),
                ], spacing: 14
            ) {
                ForEach(ALL_VOICES) { voice in
                    voiceCard(voice)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func voiceCard(_ voice: VoiceInfo) -> some View {
        let activeForVoice = vm.sessions.first { $0.voice == voice.id }
        let isSpawning = vm.spawningVoiceIds.contains(voice.id)
        let color = voiceColor(voice.id)
        let isActive = activeForVoice != nil
        let statusLabel = voiceCardLabel(active: activeForVoice, spawning: isSpawning)
        let hasBadge =
            activeForVoice.map { !$0.audioBuffer.isEmpty || $0.pendingListen } ?? false

        return VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Circle()
                        .fill(color.opacity(isActive ? 0.2 : 0.1))
                        .frame(width: 44, height: 44)
                    Image(systemName: voiceIconName(voice.id))
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(color)
                }
                if hasBadge {
                    Circle()
                        .fill(Theme.red)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(Theme.card, lineWidth: 1.5))
                        .offset(x: 2, y: -2)
                }
            }

            Text(voice.name)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)

            HStack(spacing: 5) {
                Circle()
                    .fill(voiceCardDotColor(active: activeForVoice, spawning: isSpawning))
                    .frame(width: 6, height: 6)
                Text(statusLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
                isActive || isSpawning
                    ? voiceCardDotColor(active: activeForVoice, spawning: isSpawning).opacity(0.1)
                    : Color.clear
            )
            .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.card)
                .shadow(color: Color(.label).opacity(0.06), radius: 8, y: 2)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            isActive || isSpawning
                                ? voiceCardDotColor(active: activeForVoice, spawning: isSpawning)
                                    .opacity(0.5)
                                : Theme.cardBorder,
                            lineWidth: 1
                        )
                }
        }
        .opacity(isSpawning ? 0.7 : 1.0)
        .scaleEffect(isSpawning ? 0.97 : 1.0)
        .animation(.spring(response: 0.3), value: isSpawning)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.92)) {
                if let s = activeForVoice {
                    vm.switchToSession(s.id)
                } else if !isSpawning {
                    vm.spawnSession(voiceId: voice.id)
                }
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

    private func voiceCardDotColor(active: VoiceSession?, spawning: Bool) -> Color {
        if spawning { return Theme.yellow }
        guard let s = active else { return Theme.gray3 }
        if s.status == "starting" { return Theme.yellow }
        if s.isThinking { return Theme.orange }
        let st = s.statusText
        if st == "Speaking..." || st == "Playing..." { return Theme.blue }
        if st == "Recording..." || st == "Tap Record" || s.pendingListen {
            return Theme.red
        }
        return Theme.green
    }

    private func voiceCardLabel(active: VoiceSession?, spawning: Bool) -> String {
        if spawning { return "Starting..." }
        guard let s = active else { return "Offline" }
        if s.status == "starting" { return "Starting..." }
        if s.isThinking { return "Thinking..." }
        let st = s.statusText
        if st == "Speaking..." || st == "Playing..." { return "Speaking..." }
        if st == "Recording..." || st == "Tap Record" { return "Listening..." }
        if s.pendingListen { return "Waiting..." }
        return "Ready"
    }

    // MARK: - Session View

    private var sessionView: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                sessionHeader
                chatArea
            }
            if vm.typingMode {
                textInputBar
                    .transition(.opacity)
            } else {
                controlsOverlay
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: vm.typingMode)
    }

    private var sessionHeader: some View {
        let color = vm.activeSession.flatMap { voiceColor($0.voice) } ?? Theme.textPrimary

        return HStack(spacing: 12) {
            Button { vm.goHome() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Circle()
                .fill(color)
                .frame(width: 10, height: 10)

            Text(vm.activeSession?.label ?? "Session")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            if !vm.statusText.isEmpty {
                Text(vm.statusText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.12), in: Capsule())
            }

            Button { vm.showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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

    private var connectionLabel: String {
        if vm.isConnected { return "Live" }
        if vm.isConnecting { return "Connecting..." }
        return "Offline"
    }

    // MARK: - Chat Area

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(vm.activeMessages) { msg in
                        chatBubble(msg)
                            .id(msg.id)
                    }
                    if vm.activeSession?.isThinking == true {
                        thinkingIndicator
                            .id("thinking")
                    }
                    Color.clear.frame(height: vm.isRecording ? 220 : 160)
                        .id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .onAppear {
                scrollToBottom(proxy)
            }
            .onChange(of: vm.activeMessages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: vm.activeSession?.isThinking) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: vm.activeSessionId) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    scrollToBottom(proxy)
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private func chatBubble(_ msg: ChatMessage) -> some View {
        HStack {
            if msg.role == "user" { Spacer(minLength: 50) }
            if msg.role == "system" { Spacer() }

            Text(msg.text)
                .font(msg.role == "system" ? .caption : .subheadline)
                .lineSpacing(2)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(bubbleForeground(msg.role))
                .background(bubbleBackground(msg.role), in: bubbleShape)

            if msg.role == "assistant" { Spacer(minLength: 50) }
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
        HStack {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Theme.textTertiary)
                        .frame(width: 8, height: 8)
                        .opacity(isPulsing ? 1 : 0.2)
                        .scaleEffect(isPulsing ? 1.15 : 0.7)
                        .animation(
                            .easeInOut(duration: 0.6)
                                .repeatForever()
                                .delay(Double(i) * 0.15),
                            value: isPulsing
                        )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Theme.bgSecondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onAppear { isPulsing = true }
            .onDisappear { isPulsing = false }
            Spacer(minLength: 50)
        }
    }

    // MARK: - Floating Controls

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            if vm.isRecording {
                waveformView
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            ZStack {
                // Cancel button (auto mode) - left aligned
                if vm.isRecording && !vm.pushToTalk {
                    HStack {
                        Button { vm.cancelRecording() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Theme.red)
                                .frame(width: 40, height: 40)
                                .background(Theme.red.opacity(0.12), in: Circle())
                        }
                        .transition(.scale.combined(with: .opacity))
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                }

                // Cancel label (PTT mode) - left aligned
                if vm.isRecording && vm.pushToTalk {
                    HStack {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .bold))
                            Text("Cancel")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(pttDragOffset < -80 ? Theme.red : Theme.textTertiary)
                        .opacity(pttDragOffset < -10 ? min(1.0, Double(-pttDragOffset - 10) / 60.0) : 0.3)
                        .transition(.opacity)
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                }

                // Mic button - always centered
                Group {
                    if vm.pushToTalk {
                        micButtonVisual
                            .contentShape(Circle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        vm.pttPressed()
                                        if vm.isRecording {
                                            pttDragOffset = value.translation.width
                                        }
                                    }
                                    .onEnded { _ in
                                        if pttDragOffset < -80 && vm.isRecording {
                                            vm.cancelRecording()
                                        }
                                        vm.pttReleased()
                                        pttDragOffset = 0
                                    }
                            )
                    } else {
                        Button(action: vm.micAction) {
                            micButtonVisual
                        }
                    }
                }
                .disabled(vm.isProcessing || (vm.micMuted && !vm.isPlaying && !vm.isRecording))
                .opacity(vm.isProcessing || (vm.micMuted && !vm.isPlaying) ? 0.5 : 1.0)
            }
            .padding(.top, 10)
            .padding(.bottom, 4)

            Text(micLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(micColor.opacity(0.8))
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Text Input Bar

    private var textInputBar: some View {
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
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

    private var micLabel: String {
        if vm.isPlaying { return "Interrupt" }
        if vm.isRecording {
            if vm.pushToTalk {
                return pttDragOffset < -80 ? "Release to Cancel" : "Release to Send"
            }
            return "Send"
        }
        if vm.isProcessing { return "Processing..." }
        if vm.micMuted { return "Muted" }
        return vm.pushToTalk ? "Hold to Talk" : "Record"
    }

    private var micColor: Color {
        if vm.isPlaying { return Theme.orange }
        if vm.isRecording { return Theme.green }
        if vm.isProcessing { return Theme.gray }
        if vm.micMuted { return Theme.red }
        return Theme.blue
    }

    // MARK: - Voice Colors

    private func voiceColor(_ voiceId: String) -> Color {
        switch voiceId {
        case "af_sky": return Color(hex: 0x3A86FF)    // blue
        case "af_alloy": return Color(hex: 0xE67E22)  // orange
        case "af_sarah": return Color(hex: 0xE63946)  // red
        case "am_adam": return Color(hex: 0x2ECC71)   // green
        case "am_echo": return Color(hex: 0x9B59B6)   // purple
        case "am_onyx": return Color(hex: 0x1ABC9C)   // teal
        case "bm_fable": return Color(hex: 0xF1C40F)  // gold
        default: return Color(.systemGray3)
        }
    }
}

// MARK: - Debug View

struct DebugView: View {
    @ObservedObject var vm: VoiceChatViewModel

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

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var vm: VoiceChatViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Server URL", text: $vm.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text(
                        "Enter your voice-chat hub address.\ne.g. workstation.tailee9084.ts.net:3460"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Button("Connect") {
                        vm.connect()
                        dismiss()
                    }
                    .disabled(
                        vm.serverURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Section("Model") {
                    Picker("Claude Model", selection: $vm.selectedModel) {
                        Text("Opus").tag("opus")
                        Text("Sonnet").tag("sonnet")
                        Text("Haiku").tag("haiku")
                    }
                    .onChange(of: vm.selectedModel) { _, newValue in
                        vm.updateSetting("model", value: newValue)
                    }
                    Text("Applies to newly spawned sessions only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Input Mode", selection: $vm.inputMode) {
                        Text("Auto").tag("auto")
                        Text("PTT").tag("ptt")
                        Text("Typing").tag("typing")
                    }
                    .pickerStyle(.segmented)

                    if vm.inputMode == "ptt" {
                        Text("Hold the mic button to record. Release to send. Slide left to cancel.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if vm.inputMode == "typing" {
                        Text("Type messages using the keyboard. No voice input or output.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Toggle("Auto Record", isOn: $vm.autoRecord)
                            .onChange(of: vm.autoRecord) { _, val in
                                vm.updateSetting("auto_record", value: val)
                            }
                        Toggle("Voice Detection (VAD)", isOn: $vm.vadEnabled)
                            .onChange(of: vm.vadEnabled) { _, val in
                                vm.updateSetting("auto_end", value: val)
                            }
                        Toggle("Auto Interrupt", isOn: $vm.autoInterrupt)
                            .onChange(of: vm.autoInterrupt) { _, val in
                                vm.updateSetting("auto_interrupt", value: val)
                            }
                    }
                } header: {
                    Text("Input")
                }

                if !vm.typingMode {
                    Section("Microphone") {
                        Toggle("Mic Muted", isOn: $vm.micMuted)
                    }
                }

                if vm.activeSessionId != nil {
                    Section("Session") {
                        Picker("Voice", selection: Binding(
                            get: { vm.activeVoice },
                            set: { vm.activeVoice = $0 }
                        )) {
                            ForEach(ALL_VOICES) { v in
                                Text(v.name).tag(v.id)
                            }
                        }
                        Picker("Speed", selection: Binding(
                            get: { vm.activeSpeed },
                            set: { vm.activeSpeed = $0 }
                        )) {
                            ForEach(SPEED_OPTIONS, id: \.value) { opt in
                                Text(opt.label).tag(opt.value)
                            }
                        }
                    }
                }

                Section {
                    Toggle("Background Mode", isOn: $vm.backgroundMode)
                    Text(
                        "Keep voice conversations alive when the app is in the background. Uses a silent audio loop to prevent iOS from suspending the app."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Background")
                } footer: {
                    if !vm.backgroundMode {
                        Text(
                            "When off, the WebSocket connection may drop when backgrounded."
                        )
                    }
                }

                Section("Notifications") {
                    Toggle("Auto Mode", isOn: $vm.notifyAuto)
                    Toggle("PTT Mode", isOn: $vm.notifyPTT)
                    Toggle("Typing Mode", isOn: $vm.notifyTyping)
                    Text("Notifications are sent when the agent responds while the app is in the background.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Live Activity") {
                    Toggle("Show Live Activity", isOn: $vm.liveActivityEnabled)
                    Text("Displays session status on the Dynamic Island and Lock Screen. Typing mode never shows a Live Activity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Sounds — Auto") {
                    Toggle("Thinking", isOn: $vm.soundThinkingAuto)
                    Toggle("Listening Cue", isOn: $vm.soundListeningAuto)
                    Toggle("Processing Cue", isOn: $vm.soundProcessingAuto)
                    Toggle("Session Ready", isOn: $vm.soundReadyAuto)
                }

                Section("Sounds — PTT") {
                    Toggle("Thinking", isOn: $vm.soundThinkingPTT)
                    Toggle("Session Ready", isOn: $vm.soundReadyPTT)
                }

                Section("Haptics — Auto") {
                    Toggle("Recording Start / Stop", isOn: $vm.hapticsRecordingAuto)
                    Toggle("Playback Start", isOn: $vm.hapticsPlaybackAuto)
                    Toggle("Session Events", isOn: $vm.hapticsSessionAuto)
                }

                Section("Haptics — PTT") {
                    Toggle("Recording Start / Stop", isOn: $vm.hapticsRecordingPTT)
                    Toggle("Playback Start", isOn: $vm.hapticsPlaybackPTT)
                    Toggle("Session Events", isOn: $vm.hapticsSessionPTT)
                }

                Section("Haptics — Typing") {
                    Toggle("Send Message", isOn: $vm.hapticsSend)
                    Toggle("Session Events", isOn: $vm.hapticsSessionTyping)
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
