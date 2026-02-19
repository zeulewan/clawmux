import SwiftUI

struct ContentView: View {
    @StateObject private var vm = VoiceChatViewModel()
    @State private var isPulsing = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            sessionTabBar
            if vm.activeSessionId != nil {
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
                .onTapGesture { vm.activeSessionId = nil }
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

        return VStack(spacing: 8) {
            Text(voice.name)
                .font(.system(size: 16, weight: .semibold))
            HStack(spacing: 4) {
                Circle()
                    .fill(
                        activeForVoice != nil
                            ? Color(hex: 0x2ECC71) : Color(hex: 0x555555)
                    )
                    .frame(width: 7, height: 7)
                Text(
                    activeForVoice != nil
                        ? (activeForVoice!.status == "starting"
                            ? "Starting..." : "Connected") : "Available"
                )
                .font(.caption2)
                .foregroundStyle(Color(hex: 0x888888))
            }
        }
        .frame(width: 110, height: 80)
        .background(Color(hex: 0x2A2A4A))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    activeForVoice != nil
                        ? Color(hex: 0x2ECC71) : Color.clear,
                    lineWidth: 2)
        )
        .onTapGesture {
            if let s = activeForVoice {
                vm.switchToSession(s.id)
            } else {
                vm.spawnSession(voiceId: voice.id)
            }
        }
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
                        .fill(Color(hex: 0x888888))
                        .frame(width: 8, height: 8)
                        .opacity(isPulsing ? 1 : 0.3)
                        .scaleEffect(isPulsing ? 1 : 0.8)
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
        VStack(spacing: 10) {
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

            // Mic row
            HStack(spacing: 12) {
                // Cancel button (during recording)
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

                // Main mic button
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

            // Options row
            HStack(spacing: 16) {
                // Auto-record toggle
                Toggle("Auto", isOn: $vm.autoRecord)
                    .font(.caption2)
                    .foregroundStyle(Color(hex: 0x888888))
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                // VAD toggle
                Toggle("Auto End", isOn: $vm.vadEnabled)
                    .font(.caption2)
                    .foregroundStyle(Color(hex: 0x888888))
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                // Voice picker
                Picker("", selection: Binding(
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

                // Speed picker
                Picker("", selection: Binding(
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
            }
            .padding(.horizontal, 4)
        }
        .padding(.vertical, 12)
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
                        "Enter your voice-chat hub address.\ne.g. workstation.tailee9084.ts.net"
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
