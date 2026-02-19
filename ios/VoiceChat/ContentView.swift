import SwiftUI

struct ContentView: View {
    @StateObject private var vm = VoiceChatViewModel()
    @State private var isPulsing = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            sessionTabBar
            if vm.showDebug {
                DebugView(vm: vm)
            } else if vm.activeSessionId != nil {
                chatArea
                controlsBar
            } else {
                voiceGrid
            }
        }
        .background(Color(hex: 0x1A1A2E))
        .preferredColorScheme(.dark)
        .sheet(isPresented: $vm.showSettings) {
            SettingsView(vm: vm)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text("Voice Hub")
                .font(.headline)
                .onTapGesture {
                    vm.showDebug = false
                    vm.activeSessionId = nil
                }
            Spacer()
            Circle()
                .fill(vm.isConnected ? Color(hex: 0x2ECC71) : Color(hex: 0xE63946))
                .frame(width: 10, height: 10)
            Text(vm.isConnected ? "Connected" : "Disconnected")
                .font(.caption2)
                .foregroundStyle(Color(hex: 0x888888))
            Button { vm.showSettings = true } label: {
                Image(systemName: "gear")
                    .font(.callout)
                    .foregroundStyle(Color(hex: 0x888888))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(hex: 0x16162A))
    }

    // MARK: - Session Tabs

    private var sessionTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(vm.sessions) { session in
                    sessionTab(session)
                }
                Button("+ New") { vm.spawnSession() }
                    .font(.caption)
                    .foregroundStyle(Color(hex: 0x3A86FF))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                Spacer()

                // Debug tab
                Button("Debug") {
                    vm.showDebug = true
                    vm.activeSessionId = nil
                    vm.stopThinkingSound()
                    vm.startDebugRefresh()
                }
                .font(.system(size: 11))
                .foregroundStyle(vm.showDebug ? Color(hex: 0xE0E0E0) : Color(hex: 0x666666))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    if vm.showDebug {
                        Rectangle()
                            .fill(Color(hex: 0x3A86FF))
                            .frame(height: 2)
                    }
                }
            }
        }
        .background(Color(hex: 0x12122A))
        .overlay(alignment: .bottom) {
            Divider().background(Color(hex: 0x2A2A4A))
        }
    }

    private func sessionTab(_ session: VoiceSession) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tabDotColor(session.status))
                .frame(width: 6, height: 6)
            Text(session.label)
                .font(.caption)
                .lineLimit(1)
            Button {
                vm.terminateSession(session.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color(hex: 0x666666))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .foregroundStyle(
            session.id == vm.activeSessionId
                ? Color(hex: 0xE0E0E0) : Color(hex: 0x888888)
        )
        .background(
            session.id == vm.activeSessionId
                ? Color(hex: 0x1A1A2E) : Color.clear
        )
        .overlay(alignment: .bottom) {
            if session.id == vm.activeSessionId {
                Rectangle()
                    .fill(Color(hex: 0x3A86FF))
                    .frame(height: 2)
            }
        }
        .onTapGesture { vm.switchToSession(session.id) }
    }

    private func tabDotColor(_ status: String) -> Color {
        switch status {
        case "ready": Color(hex: 0x2ECC71)
        case "starting": Color(hex: 0xF1C40F)
        case "active": Color(hex: 0x3A86FF)
        default: Color(hex: 0x888888)
        }
    }

    // MARK: - Voice Grid (Landing)

    private var voiceGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 100), spacing: 12)
                ], spacing: 12
            ) {
                ForEach(ALL_VOICES) { voice in
                    voiceCard(voice)
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func voiceCard(_ voice: VoiceInfo) -> some View {
        let activeForVoice = vm.sessions.first { $0.voice == voice.id }
        let isSpawning = vm.spawningVoiceId == voice.id

        return VStack(spacing: 8) {
            Text(voice.name)
                .font(.system(size: 16, weight: .semibold))
            HStack(spacing: 4) {
                Circle()
                    .fill(voiceCardDotColor(active: activeForVoice, spawning: isSpawning))
                    .frame(width: 7, height: 7)
                Text(voiceCardLabel(active: activeForVoice, spawning: isSpawning))
                    .font(.caption2)
                    .foregroundStyle(Color(hex: 0x888888))
            }
        }
        .frame(width: 110, height: 80)
        .background(Color(hex: 0x2A2A4A))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(voiceCardBorderColor(active: activeForVoice, spawning: isSpawning),
                    lineWidth: 2)
        )
        .opacity(isSpawning ? 0.7 : 1.0)
        .onTapGesture {
            if let s = activeForVoice {
                vm.switchToSession(s.id)
            } else if !isSpawning {
                vm.spawnSession(voiceId: voice.id)
            }
        }
    }

    private func voiceCardDotColor(active: VoiceSession?, spawning: Bool) -> Color {
        if spawning { return Color(hex: 0xF1C40F) }
        if let s = active {
            return s.status == "starting" ? Color(hex: 0xF1C40F) : Color(hex: 0x2ECC71)
        }
        return Color(hex: 0x555555)
    }

    private func voiceCardLabel(active: VoiceSession?, spawning: Bool) -> String {
        if spawning { return "Starting..." }
        if let s = active {
            return s.status == "starting" ? "Starting..." : "Connected"
        }
        return "Available"
    }

    private func voiceCardBorderColor(active: VoiceSession?, spawning: Bool) -> Color {
        if spawning { return Color(hex: 0xF1C40F) }
        if active != nil { return Color(hex: 0x2ECC71) }
        return Color.clear
    }

    // MARK: - Chat Area

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(vm.activeMessages) { msg in
                        chatBubble(msg)
                            .id(msg.id)
                    }
                    if vm.activeSession?.isThinking == true {
                        thinkingIndicator
                    }
                }
                .padding()
            }
            .onChange(of: vm.activeMessages.count) { _, _ in
                if let last = vm.activeMessages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func chatBubble(_ msg: ChatMessage) -> some View {
        HStack {
            if msg.role == "user" { Spacer(minLength: 40) }
            if msg.role == "system" { Spacer() }

            Text(msg.text)
                .font(msg.role == "system" ? .caption : .callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleBackground(msg.role))
                .foregroundStyle(bubbleForeground(msg.role))
                .clipShape(RoundedRectangle(cornerRadius: 14))

            if msg.role == "assistant" { Spacer(minLength: 40) }
            if msg.role == "system" { Spacer() }
        }
    }

    private func bubbleBackground(_ role: String) -> Color {
        switch role {
        case "user": Color(hex: 0x3A86FF)
        case "assistant": Color(hex: 0x2A2A4A)
        default: Color.clear
        }
    }

    private func bubbleForeground(_ role: String) -> Color {
        switch role {
        case "user": .white
        case "system": Color(hex: 0x666666)
        default: Color(hex: 0xE0E0E0)
        }
    }

    private var thinkingIndicator: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color(hex: 0x999999))
                        .frame(width: 10, height: 10)
                        .opacity(isPulsing ? 1 : 0.2)
                        .scaleEffect(isPulsing ? 1.1 : 0.7)
                        .animation(
                            .easeInOut(duration: 0.7)
                                .repeatForever()
                                .delay(Double(i) * 0.2),
                            value: isPulsing
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(hex: 0x2A2A4A))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .onAppear { isPulsing = true }
            .onDisappear { isPulsing = false }
            Spacer(minLength: 40)
        }
    }

    // MARK: - Controls Bar

    private var controlsBar: some View {
        VStack(spacing: 8) {
            // Session info
            if let tmux = vm.activeSession?.tmuxSession, !tmux.isEmpty {
                Text(tmux)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(hex: 0x555555))
            }

            // Status
            Text(vm.statusText)
                .font(.caption)
                .foregroundStyle(Color(hex: 0x888888))
                .lineLimit(1)

            // Mic row
            HStack(spacing: 12) {
                if vm.isRecording {
                    Button { vm.cancelRecording() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 40, height: 40)
                            .overlay(
                                Circle().stroke(Color(hex: 0xE63946), lineWidth: 2)
                            )
                            .foregroundStyle(Color(hex: 0xE63946))
                    }
                }

                Button(action: vm.micAction) {
                    HStack(spacing: 6) {
                        Image(systemName: micIcon)
                            .font(.system(size: 14, weight: .semibold))
                        Text(micLabel)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(height: 48)
                    .background(micColor)
                    .clipShape(Capsule())
                    .opacity(vm.isProcessing ? 0.5 : 1.0)
                }
                .disabled(vm.isProcessing)
            }

            // Options: two rows for compact layout
            VStack(spacing: 6) {
                HStack(spacing: 16) {
                    Toggle("Auto", isOn: $vm.autoRecord)
                        .font(.caption2)
                        .foregroundStyle(Color(hex: 0x888888))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .fixedSize()

                    Toggle("VAD", isOn: $vm.vadEnabled)
                        .font(.caption2)
                        .foregroundStyle(Color(hex: 0x888888))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .fixedSize()

                    Spacer()

                    Picker("Voice", selection: Binding(
                        get: { vm.activeVoice },
                        set: { vm.activeVoice = $0 }
                    )) {
                        ForEach(ALL_VOICES) { v in
                            Text(v.name).tag(v.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.caption2)
                    .tint(Color(hex: 0xE0E0E0))
                    .fixedSize()

                    Picker("Speed", selection: Binding(
                        get: { vm.activeSpeed },
                        set: { vm.activeSpeed = $0 }
                    )) {
                        ForEach(SPEED_OPTIONS, id: \.value) { opt in
                            Text(opt.label).tag(opt.value)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.caption2)
                    .tint(Color(hex: 0xE0E0E0))
                    .fixedSize()
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(.vertical, 10)
        .padding(.horizontal)
        .background(Color(hex: 0x16162A))
    }

    private var micIcon: String {
        if vm.isPlaying { return "hand.raised.fill" }
        if vm.isRecording { return "arrow.up.circle.fill" }
        return "mic.fill"
    }

    private var micLabel: String {
        if vm.isPlaying { return "Interrupt" }
        if vm.isRecording { return "Send" }
        if vm.isProcessing { return "Processing..." }
        return "Record"
    }

    private var micColor: Color {
        if vm.isPlaying { return Color(hex: 0xE67E22) }
        if vm.isRecording { return Color(hex: 0x2ECC71) }
        if vm.isProcessing { return Color(hex: 0x555555) }
        return Color(hex: 0x3A86FF)
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
                        .foregroundStyle(Color(hex: 0x555555))
                }

                // Hub
                debugSection("Hub") {
                    debugKV("Port", "\(vm.debugHub.port)")
                    debugKV("Uptime", formatDuration(vm.debugHub.uptimeSeconds))
                    debugKV("Browser", vm.debugHub.browserConnected ? "connected" : "disconnected",
                        badge: vm.debugHub.browserConnected ? .up : .down)
                    debugKV("Sessions", "\(vm.debugHub.sessionCount)")
                }

                // Services
                debugSection("Services") {
                    if vm.debugServices.isEmpty {
                        Text("Loading...")
                            .font(.caption)
                            .foregroundStyle(Color(hex: 0x555555))
                    } else {
                        ForEach(vm.debugServices) { svc in
                            HStack(spacing: 8) {
                                Text(svc.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(width: 60, alignment: .leading)
                                debugBadge(svc.status, style: svc.status == "up" ? .up : .down)
                                Text(svc.detail)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color(hex: 0x555555))
                                    .lineLimit(1)
                                Spacer()
                            }
                        }
                    }
                }

                // Hub Sessions
                debugSection("Hub Sessions") {
                    if vm.debugSessions.isEmpty {
                        Text("No active sessions")
                            .font(.caption)
                            .foregroundStyle(Color(hex: 0x555555))
                    } else {
                        ForEach(vm.debugSessions) { s in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(s.sessionId)
                                        .font(.system(size: 11, design: .monospaced))
                                        .lineLimit(1)
                                    debugBadge(s.status,
                                        style: s.status == "ready" ? .up : .starting)
                                    debugBadge(s.mcpConnected ? "mcp" : "no mcp",
                                        style: s.mcpConnected ? .up : .down)
                                }
                                HStack(spacing: 12) {
                                    Text(s.voice)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color(hex: 0x888888))
                                    Text("idle \(formatDuration(s.idleSeconds))")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color(hex: 0x666666))
                                    Text("age \(formatDuration(s.ageSeconds))")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color(hex: 0x666666))
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                // tmux Sessions
                debugSection("tmux Sessions") {
                    if vm.debugTmux.isEmpty {
                        Text("No tmux sessions")
                            .font(.caption)
                            .foregroundStyle(Color(hex: 0x555555))
                    } else {
                        ForEach(vm.debugTmux) { t in
                            HStack(spacing: 8) {
                                Text(t.name)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                debugBadge(t.isVoice ? "voice" : "other",
                                    style: t.isVoice ? .starting : .down)
                                Text("\(t.windows)w")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color(hex: 0x666666))
                                Text(t.created)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color(hex: 0x555555))
                                Spacer()
                            }
                        }
                    }
                }

                // Hub Log
                debugSection("Hub Log") {
                    ScrollView {
                        Text(vm.debugLog.joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color(hex: 0xAAAAAA))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 300)
                    .padding(8)
                    .background(Color(hex: 0x0D0D1A))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(hex: 0x2A2A4A), lineWidth: 1)
                    )
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear {
            vm.stopDebugRefresh()
        }
    }

    // MARK: - Debug Helpers

    enum BadgeStyle { case up, down, starting }

    @ViewBuilder
    private func debugSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: 0x3A86FF))
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0x16162A))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(hex: 0x2A2A4A), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func debugKV(_ key: String, _ value: String, badge: BadgeStyle? = nil) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: 0x666666))
                .frame(width: 80, alignment: .leading)
            if let badge {
                debugBadge(value, style: badge)
            } else {
                Text(value)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0xE0E0E0))
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func debugBadge(_ text: String, style: BadgeStyle) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(badgeBg(style))
            .foregroundStyle(badgeFg(style))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func badgeBg(_ style: BadgeStyle) -> Color {
        switch style {
        case .up: Color(hex: 0x2ECC71).opacity(0.2)
        case .down: Color(hex: 0xE63946).opacity(0.2)
        case .starting: Color(hex: 0xF1C40F).opacity(0.15)
        }
    }

    private func badgeFg(_ style: BadgeStyle) -> Color {
        switch style {
        case .up: Color(hex: 0x2ECC71)
        case .down: Color(hex: 0xE63946)
        case .starting: Color(hex: 0xF1C40F)
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
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        vm.connect()
                        dismiss()
                    }
                    .disabled(
                        vm.serverURL.trimmingCharacters(in: .whitespaces)
                            .isEmpty)
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
