import SwiftUI

// MARK: - Theme (dark-mode-first, used by all views in this file)

private enum Theme {
    // These render correctly under forced dark mode
    static let bg            = Color(.systemBackground)
    static let bgSecondary   = Color(.secondarySystemBackground)
    static let textPrimary   = Color(.label)
    static let textSecondary = Color(.secondaryLabel)
    static let textTertiary  = Color(.tertiaryLabel)
    static let blue          = Color(.systemBlue)
    static let green         = Color(.systemGreen)
    static let red           = Color(.systemRed)
    static let orange        = Color(.systemOrange)
    static let yellow        = Color(.systemYellow)
    static let gray          = Color(.systemGray)
    static let gray3         = Color(.systemGray3)
    static let gray5         = Color(.systemGray5)
}

// MARK: - Canvas Colors (dark atmospheric palette)

private extension Color {
    static let canvas1     = Color(hex: 0x06090F)   // deep navy (matches browser --bg)
    static let canvas2     = Color(hex: 0x0D1117)   // dark steel (matches browser --bg-secondary)
    static let glass       = Color.white.opacity(0.06)
    static let glassBright = Color.white.opacity(0.10)
    static let glassBorder = Color.white.opacity(0.08)
    static let cText       = Color(hex: 0xEEF2FF)   // browser --text
    static let cTextSec    = Color(hex: 0x94A3B8)   // browser --text-secondary
    static let cTextTer    = Color(hex: 0x7A8BA3)   // browser --text-tertiary
    static let cAccent     = Color(hex: 0x818CF8)   // browser --blue (indigo, not blue!)
    static let cDanger     = Color(hex: 0xFF453A)   // browser --red
    static let cSuccess    = Color(hex: 0x30D158)
    static let cWarning    = Color(hex: 0xFF9F0A)
    static let cCard       = Color(hex: 0x141B26)   // browser --bg-card
    static let cBorder     = Color(hex: 0x1E2A3D)   // browser --border
}

// MARK: - File-level Helpers

private func voiceColor(_ id: String) -> Color {
    switch id {
    case "af_sky":   return Color(hex: 0x3A86FF)
    case "af_alloy": return Color(hex: 0xE67E22)
    case "af_sarah": return Color(hex: 0xE63946)
    case "am_adam":  return Color(hex: 0x2ECC71)
    case "am_echo":  return Color(hex: 0x9B59B6)
    case "am_onyx":  return Color(hex: 0x7F8C8D)
    case "bm_fable": return Color(hex: 0xF1C40F)
    default:         return Color(hex: 0x8E8E93)
    }
}

private func voiceIcon(_ id: String) -> String {
    switch id {
    case "af_sky":   return "cloud.fill"
    case "af_alloy": return "diamond.fill"
    case "af_sarah": return "heart.fill"
    case "am_adam":  return "leaf.fill"
    case "am_echo":  return "waveform"
    case "am_onyx":  return "shield.fill"
    case "bm_fable": return "book.fill"
    default:         return "person.fill"
    }
}

private func usageColor(_ pct: Int) -> Color {
    if pct >= 80 { return .cDanger }
    if pct >= 60 { return .cWarning }
    return .cSuccess
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var vm = ClawMuxViewModel()
    @State private var showingChat    = false
    @State private var isPulsing      = false
    @State private var showResetConfirm      = false
    @State private var resetVoiceId: String? = nil
    @State private var showModelRestartConfirm = false
    @State private var pendingModelSwitch      = ""
    @State private var pttDragOffset:  CGFloat = 0
    @State private var pttDragOffsetY: CGFloat = 0
    @State private var pttGestureCommitted     = false
    @FocusState private var pttTextFieldFocused: Bool
    @State private var showCopiedToast         = false
    @State private var thinkingExpanded        = false
    @State private var collapsedProjects:       Set<String> = []
    @State private var isAtBottom:             Bool = true

    var body: some View {
        ZStack {
            // Deep atmospheric canvas matching browser palette
            Color.canvas1.ignoresSafeArea()

            if showingChat && vm.activeSessionId != nil {
                chatView
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing),
                        removal:   .move(edge: .trailing)
                    ))
            } else {
                sessionListView
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading),
                        removal:   .move(edge: .leading)
                    ))
            }
        }
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: showingChat)
        .onAppear { isPulsing = true }
        .onChange(of: vm.activeSessionId) { _, new in
            if new == nil { withAnimation { showingChat = false } }
        }
        .sheet(isPresented: $vm.showSettings) { SettingsView(vm: vm) }
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
        .alert("Error", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) { Button("OK") { vm.errorMessage = nil }
        } message: { Text(vm.errorMessage ?? "") }
    }

    // MARK: - Session List

    private var sessionListView: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ClawMux")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.cText)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(vm.isConnected ? Color.cSuccess : vm.isConnecting ? Color.cWarning : Color.cDanger)
                            .frame(width: 5, height: 5)
                        Text(vm.isConnected ? "Connected" : vm.isConnecting ? "Connecting…" : "Offline")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.cTextSec)
                    }
                }
                Spacer()
                Button { vm.showSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.cTextSec)
                        .frame(width: 40, height: 40)
                        .background(Color.glass, in: Circle())
                        .overlay(Circle().strokeBorder(Color.glassBorder, lineWidth: 0.5))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    let groups = projectGroups
                    // Named project sections
                    ForEach(groups.namedProjects, id: \.self) { project in
                        projectSection(project, voices: groups.byProject[project] ?? [])
                    }
                    // Ungrouped agents
                    if !groups.ungrouped.isEmpty {
                        if !groups.namedProjects.isEmpty {
                            HStack {
                                Text("AGENTS")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.cTextTer)
                                    .tracking(0.8)
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 16).padding(.bottom, 6)
                        }
                        VStack(spacing: 6) {
                            ForEach(groups.ungrouped) { voice in agentCard(voice) }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Project Grouping

    private struct ProjectGroups {
        let namedProjects: [String]
        let byProject:     [String: [VoiceInfo]]
        let ungrouped:     [VoiceInfo]
    }

    private var projectGroups: ProjectGroups {
        var byProject: [String: [VoiceInfo]] = [:]
        var ungrouped: [VoiceInfo] = []
        for voice in ALL_VOICES {
            let project = vm.sessions.first { $0.voice == voice.id }?.project ?? ""
            if project.isEmpty { ungrouped.append(voice) }
            else { byProject[project, default: []].append(voice) }
        }
        return ProjectGroups(namedProjects: byProject.keys.sorted(), byProject: byProject, ungrouped: ungrouped)
    }

    @ViewBuilder
    private func projectSection(_ project: String, voices: [VoiceInfo]) -> some View {
        let collapsed = collapsedProjects.contains(project)
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    if collapsed { collapsedProjects.remove(project) }
                    else         { collapsedProjects.insert(project) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.cTextTer)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        .animation(.spring(response: 0.3), value: collapsed)
                    Text(project.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.cTextTer)
                        .tracking(0.8)
                    Text("\(voices.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.cTextTer.opacity(0.55))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16).padding(.bottom, 6)
            }
            .buttonStyle(.plain)

            if !collapsed {
                VStack(spacing: 6) {
                    ForEach(voices) { voice in agentCard(voice) }
                }
                .padding(.horizontal, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func agentCard(_ voice: VoiceInfo) -> some View {
        let session    = vm.sessions.first { $0.voice == voice.id }
        let spawning   = vm.spawningVoiceIds.contains(voice.id)
        let isSelected = vm.activeSession?.voice == voice.id && showingChat
        let color      = voiceColor(voice.id)
        let alive      = session != nil || spawning
        let thinking   = session?.isThinking == true
        let rc         = ringColor(session, spawning: spawning)

        return Button {
            if let s = session {
                vm.switchToSession(s.id)
                withAnimation { showingChat = true }
            } else if !spawning {
                vm.spawnSession(voiceId: voice.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if vm.activeSessionId != nil { withAnimation { showingChat = true } }
                }
            }
        } label: {
            HStack(spacing: 14) {
                // Avatar + state ring
                ZStack {
                    if thinking {
                        Circle()
                            .strokeBorder(color.opacity(isPulsing ? 0.45 : 0.05), lineWidth: 8)
                            .frame(width: 60, height: 60)
                            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isPulsing)
                    }
                    Circle()
                        .fill(color.opacity(alive ? 0.16 : 0.06))
                        .frame(width: 46, height: 46)
                    if alive {
                        Circle()
                            .strokeBorder(rc, lineWidth: 2)
                            .frame(width: 46, height: 46)
                            .shadow(color: rc.opacity(0.45), radius: 5)
                    }
                    Image(systemName: voiceIcon(voice.id))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(alive ? color : color.opacity(0.30))
                }
                .frame(width: 60, height: 60)

                // Name + area + role + task + status  (hub.html hierarchy)
                VStack(alignment: .leading, spacing: 2) {
                    Text(voice.name)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(alive ? Color.cText : Color.cTextTer)
                        .lineLimit(1)
                    if let s = session, alive {
                        if !s.projectArea.isEmpty {
                            Text(s.projectArea.uppercased())
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Color.cAccent.opacity(0.85))
                                .tracking(0.6)
                                .lineLimit(1)
                        }
                        if !s.role.isEmpty {
                            Text(s.role)
                                .font(.system(size: 9))
                                .foregroundStyle(Color.cTextSec)
                                .lineLimit(1)
                        }
                        if !s.task.isEmpty {
                            Text(s.task)
                                .font(.system(size: 9))
                                .foregroundStyle(Color.cTextTer)
                                .lineLimit(2).truncationMode(.tail)
                        }
                    }
                    Text(cardStatus(session, spawning: spawning))
                        .font(.system(size: 9))
                        .foregroundStyle(alive ? Color.cTextSec : Color.cTextTer)
                        .lineLimit(1)
                }

                Spacer()

                // Unread badge
                if let u = session?.unreadCount, u > 0 {
                    Text("\(u)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Color.cDanger, in: Circle())
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(alive ? Color.cTextTer : Color(hex: 0x2A3A52))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isSelected ? color.opacity(0.08) : Color.cCard)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(isSelected ? color.opacity(0.3) : Color.cBorder, lineWidth: 0.5)
                        )
                    // Left accent bar (hub.html selected indicator)
                    if isSelected {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(color)
                            .frame(width: 3)
                            .padding(.vertical, 10)
                            .shadow(color: color.opacity(0.6), radius: 4)
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let s = session {
                Button(role: .destructive) { vm.terminateSession(s.id) } label: {
                    Label("End Session", systemImage: "xmark.circle")
                }
            }
            Button(role: .destructive) { resetVoiceId = voice.id; showResetConfirm = true } label: {
                Label("Reset History", systemImage: "trash")
            }
        }
    }

    private func ringColor(_ session: VoiceSession?, spawning: Bool) -> Color {
        if spawning { return .cWarning }
        guard let s = session else { return Color(hex: 0x48484A) }
        if s.state == .starting { return .cWarning }
        if s.unreadCount > 0   { return .cDanger }
        if s.isThinking        { return .cWarning }
        let st = s.statusText
        if st == "Speaking..." || st == "Playing..." { return .cAccent }
        return .cSuccess
    }

    private func cardStatus(_ session: VoiceSession?, spawning: Bool) -> String {
        if spawning { return "Starting…" }
        guard let s = session else { return "Tap to start" }
        if s.state == .starting { return "Starting…" }
        if s.isThinking { return s.activity.isEmpty ? "Thinking…" : s.activity }
        if s.unreadCount > 1 { return "\(s.unreadCount) new messages" }
        if s.unreadCount == 1 { return "1 new message" }
        let st = s.statusText
        return st.isEmpty ? "Idle" : st
    }

    // MARK: - Chat View

    private var chatView: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if vm.showDebug {
                    chatHeader
                    DebugView(vm: vm)
                } else {
                    chatHeader
                    chatScrollArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    bottomInputArea
                }
            }
            // Copy toast
            if showCopiedToast {
                Text("Copied")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.cText)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(Color.cCard, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.cBorder, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.4), radius: 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                    .padding(.top, 68)
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: showCopiedToast)
    }

    // MARK: - Chat Header

    private var chatHeader: some View {
        let color = vm.activeSession.map { voiceColor($0.voice) } ?? Color.cTextSec
        return HStack(spacing: 12) {
            // Back
            Button {
                withAnimation { showingChat = false }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.cTextSec)
                    .frame(width: 36, height: 36)
                    .background(Color.glass, in: Circle())
                    .overlay(Circle().strokeBorder(Color.cBorder, lineWidth: 0.5))
            }

            if let s = vm.activeSession {
                // Agent avatar
                ZStack {
                    Circle().fill(color.opacity(0.16)).frame(width: 36, height: 36)
                    Image(systemName: voiceIcon(s.voice))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(color)
                }

                // Name + subtitle
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.showDebug ? "Debug" : s.label)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cText)
                        .lineLimit(1)
                    Group {
                        if !s.role.isEmpty || !s.task.isEmpty {
                            HStack(spacing: 3) {
                                if !s.role.isEmpty {
                                    Text(s.role).italic().foregroundStyle(color.opacity(0.9))
                                }
                                if !s.role.isEmpty && !s.task.isEmpty {
                                    Text("·").foregroundStyle(Color.cTextTer)
                                }
                                if !s.task.isEmpty {
                                    Text(s.task).foregroundStyle(Color.cTextTer).lineLimit(1)
                                }
                            }
                        } else if !s.project.isEmpty {
                            Text(s.projectArea.isEmpty ? s.project : "\(s.project) · \(s.projectArea)")
                                .foregroundStyle(Color.cTextTer).lineLimit(1)
                        } else {
                            let stateColor = ringColor(s, spawning: false)
                            HStack(spacing: 4) {
                                Circle().fill(stateColor).frame(width: 5, height: 5)
                                Text(s.statusText.isEmpty ? "Idle" : s.statusText)
                                    .foregroundStyle(Color.cTextTer)
                            }
                        }
                    }
                    .font(.system(size: 11))
                }
            }

            Spacer()

            // Model picker
            if vm.activeSessionId != nil {
                let cur = vm.activeSession?.model ?? ""
                Menu {
                    ForEach([("opus","Opus"),("sonnet","Sonnet"),("haiku","Haiku")], id: \.0) { id, name in
                        Button {
                            if cur != id { pendingModelSwitch = id; showModelRestartConfirm = true }
                        } label: {
                            HStack {
                                Text(name)
                                if cur == id || (id == "opus" && cur.isEmpty) { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    Text(modelName(vm.activeSession?.model ?? ""))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cTextSec)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.cCard, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.cBorder, lineWidth: 0.5))
                }
            }

            // Settings
            Button { vm.showSettings = true } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.cTextSec)
                    .frame(width: 36, height: 36)
                    .background(Color.glass, in: Circle())
                    .overlay(Circle().strokeBorder(Color.cBorder, lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background {
            if #available(iOS 26, *) {
                Color.clear.glassEffect(.regular, in: .rect)
            } else {
                Color.canvas1.opacity(0.95)
            }
        }
    }

    private func modelName(_ m: String) -> String {
        switch m { case "sonnet": "Sonnet"; case "haiku": "Haiku"; default: "Opus" }
    }

    // MARK: - Chat Scroll Area

    private var chatScrollArea: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        Spacer(minLength: 0).frame(maxHeight: .infinity)
                        ForEach(messageGroups) { group in
                            messageGroupView(group).id(group.id)
                        }
                        if vm.activeSession?.isThinking == true {
                            thinkingBubble.id("thinking")
                        }
                        // Bottom anchor
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16).padding(.bottom, 16)
                    .frame(minHeight: geo.size.height)
                }
                .defaultScrollAnchor(.bottom)
                .id(vm.activeSessionId ?? "none")
                .modifier(ScrollBottomDetector(isAtBottom: $isAtBottom))
                .onChange(of: vm.activeMessages.count)        { _, _ in scrollBottom(proxy) }
                .onChange(of: vm.activeSession?.isThinking)   { _, thinking in
                    if thinking != true { thinkingExpanded = false }
                    scrollBottom(proxy)
                }
                .onChange(of: vm.activeSession?.activity)     { _, _ in scrollBottom(proxy) }
                .onChange(of: vm.activeSessionId)             { _, _ in
                    isAtBottom = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { scrollBottom(proxy) }
                }
            }
        }
    }

    private func scrollBottom(_ proxy: ScrollViewProxy) {
        guard isAtBottom else { return }
        withAnimation(.spring(response: 0.3)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    // MARK: - Message Grouping

    private struct MessageGroup: Identifiable {
        let id = UUID()
        let role: String
        let messages: [ChatMessage]
    }

    private var messageGroups: [MessageGroup] {
        let filtered = vm.activeMessages.filter { msg in
            if msg.role == "system" || msg.role == "agent" { return vm.verboseMode }
            return true
        }
        var groups: [MessageGroup] = []
        var cur: String? = nil
        var batch: [ChatMessage] = []
        for msg in filtered {
            if msg.role == cur {
                batch.append(msg)
            } else {
                if !batch.isEmpty { groups.append(MessageGroup(role: cur!, messages: batch)) }
                cur = msg.role; batch = [msg]
            }
        }
        if !batch.isEmpty { groups.append(MessageGroup(role: cur!, messages: batch)) }
        return groups
    }

    private func messageGroupView(_ group: MessageGroup) -> some View {
        let color = vm.activeSession.map { voiceColor($0.voice) } ?? Color.cTextSec
        return VStack(alignment: group.role == "user" ? .trailing : .leading, spacing: 3) {
            ForEach(Array(group.messages.enumerated()), id: \.element.id) { idx, msg in
                chatBubble(msg,
                    isFirst: idx == 0,
                    isLast:  idx == group.messages.count - 1,
                    role:    group.role)
            }
        }
    }

    private func chatBubble(_ msg: ChatMessage, isFirst: Bool, isLast: Bool, role: String) -> some View {
        let color     = vm.activeSession.map { voiceColor($0.voice) } ?? Color.cTextSec
        let isPlaying = vm.ttsPlayingMessageId == msg.id

        // Web-matched grouping: flatten tail corners in group, tail 4px on last
        let single = isFirst && isLast
        let tl: CGFloat = (role == "assistant" && !isFirst)  ? 8 : 18
        let bl: CGFloat = role == "assistant" ? (isLast ? 4 : single ? 18 : 8) : 18
        let tr: CGFloat = (role == "user"      && !isFirst)  ? 8 : 18
        let br: CGFloat = role == "user"      ? (isLast ? 4 : single ? 18 : 8) : 18

        let userBubbleColor = Color(hex: 0x2563EB)
        let bubbleBg: AnyShapeStyle = role == "user"
            ? AnyShapeStyle(userBubbleColor)
            : role == "assistant"
                ? AnyShapeStyle(isPlaying ? color.opacity(0.22) : Color.cCard)
                : role == "agent"
                    ? AnyShapeStyle(Color.cAccent.opacity(0.08))
                    : AnyShapeStyle(Color.clear)

        return HStack(alignment: .bottom, spacing: 0) {
            if role == "user"   { Spacer(minLength: 56) }
            if role == "system" { Spacer() }

            VStack(alignment: role == "user" ? .trailing : .leading, spacing: 0) {
                Group {
                    if role == "assistant" {
                        MarkdownContentView(text: msg.text, foreground: Color.cText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if role == "user" {
                        Text(LocalizedStringKey(msg.text))
                            .font(.system(size: 15))
                            .lineSpacing(2)
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    } else if role == "agent" {
                        Text(msg.text)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.cAccent.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(msg.text)
                            .font(.caption)
                            .foregroundStyle(Color.cTextTer)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(.horizontal, 13).padding(.top, 9).padding(.bottom, 4)

                if role != "system" {
                    Text(shortTime(msg.timestamp))
                        .font(.system(size: 9))
                        .foregroundStyle(role == "user" ? Color.white.opacity(0.45) : Color.cTextTer)
                        .padding(.horizontal, 11).padding(.bottom, 6)
                        .frame(maxWidth: .infinity, alignment: role == "user" ? .trailing : .leading)
                }
            }
            .background(bubbleBg,
                in: UnevenRoundedRectangle(
                    topLeadingRadius: tl, bottomLeadingRadius: bl,
                    bottomTrailingRadius: br, topTrailingRadius: tr,
                    style: .continuous))
            .overlay {
                if role == "assistant" {
                    UnevenRoundedRectangle(
                        topLeadingRadius: tl, bottomLeadingRadius: bl,
                        bottomTrailingRadius: br, topTrailingRadius: tr,
                        style: .continuous)
                    .strokeBorder(
                        isPlaying ? color.opacity(isPulsing ? 0.7 : 0.2) : Color.cBorder,
                        lineWidth: 0.5)
                    .animation(
                        isPlaying ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true) : .default,
                        value: isPulsing)
                }
            }
            .contextMenu {
                Button {
                    UIPasteboard.general.string = msg.text
                    withAnimation { showCopiedToast = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { showCopiedToast = false }
                    }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }

            if role == "assistant" || role == "agent" { Spacer(minLength: 56) }
            if role == "system"   { Spacer() }
        }
    }

    private func shortTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = Calendar.current.isDateInToday(date) ? "h:mm a" : "MMM d, h:mm a"
        return fmt.string(from: date)
    }

    // MARK: - Thinking Bubble

    private var thinkingBubble: some View {
        let color   = vm.activeSession.map { voiceColor($0.voice) } ?? Color.cTextSec
        let session = vm.activeSession
        let hasDetail = session.map { !$0.activity.isEmpty || !$0.toolName.isEmpty } ?? false

        return HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                // Dots row + activity summary (always visible)
                Button {
                    guard hasDetail else { return }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        thinkingExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        // Bouncing dots
                        HStack(spacing: 5) {
                            ForEach(0..<3, id: \.self) { i in
                                Circle()
                                    .fill(color.opacity(0.75))
                                    .frame(width: 7, height: 7)
                                    .offset(y: isPulsing ? -4 : 4)
                                    .animation(
                                        .easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(Double(i) * 0.18),
                                        value: isPulsing)
                            }
                        }
                        if hasDetail, let s = session {
                            let summary = s.activity.isEmpty ? s.toolName : s.activity
                            Text(summary)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(color.opacity(0.8))
                                .lineLimit(1).truncationMode(.middle)
                        }
                        if hasDetail {
                            Image(systemName: thinkingExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.cTextTer)
                        }
                    }
                }
                .buttonStyle(.plain)

                // Expanded detail
                if thinkingExpanded, let s = session, hasDetail {
                    VStack(alignment: .leading, spacing: 2) {
                        if !s.activity.isEmpty {
                            Text(s.activity)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(color.opacity(0.9))
                        }
                        if !s.toolName.isEmpty {
                            Text(s.toolName)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.cTextTer)
                                .lineLimit(2).truncationMode(.middle)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(Color.cCard,
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 4, bottomLeadingRadius: 4,
                    bottomTrailingRadius: 18, topTrailingRadius: 18,
                    style: .continuous))
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 4, bottomLeadingRadius: 4,
                    bottomTrailingRadius: 18, topTrailingRadius: 18,
                    style: .continuous)
                .strokeBorder(Color.cBorder, lineWidth: 0.5))
            .onAppear  { isPulsing = true }
            .onDisappear { isPulsing = false }

            Button { vm.sendInterrupt() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.cDanger)
                    .frame(width: 30, height: 30)
                    .background(Color.cDanger.opacity(0.15), in: Circle())
                    .overlay(Circle().strokeBorder(Color.cDanger.opacity(0.25), lineWidth: 0.5))
            }
            Spacer(minLength: 40)
        }
    }

    // MARK: - Bottom Input Area

    @ViewBuilder
    private var bottomInputArea: some View {
        if vm.typingMode {
            textInputBar.transition(.opacity)
        } else if vm.pushToTalk && vm.showPTTTextField {
            pttTextInputBar.transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            voiceControlBar.transition(.opacity)
        }
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

                // Main row: cancel / mic / text-hint
                HStack(alignment: .center) {
                    if vm.isPlaying {
                        // Stop TTS playback
                        Button { vm.interruptPlayback() } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Color.cDanger)
                                .frame(width: 44, height: 44)
                                .background(Color.cDanger.opacity(0.12), in: Circle())
                                .overlay(Circle().strokeBorder(Color.cDanger.opacity(0.25), lineWidth: 0.5))
                        }
                        .transition(.scale.combined(with: .opacity))
                    } else if vm.isRecording && !vm.pushToTalk {
                        Button { vm.cancelRecording() } label: {
                            Image(systemName: "xmark").font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Color.cDanger)
                                .frame(width: 40, height: 40)
                                .background(Color.cDanger.opacity(0.15), in: Circle())
                        }
                        .transition(.scale.combined(with: .opacity))
                    } else if vm.isRecording && vm.pushToTalk {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                            Text("Cancel").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(pttDragOffset < -80 ? Color.cDanger : Color.cTextTer)
                        .opacity(pttDragOffset < -10 ? min(1, Double(-pttDragOffset - 10) / 60) : 0.3)
                        .frame(width: 60).transition(.opacity)
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
                    .disabled(vm.isProcessing || vm.recordBlockedByThinking || (vm.micMuted && !vm.isPlaying && !vm.isRecording))
                    .opacity(vm.isProcessing || vm.recordBlockedByThinking || (vm.micMuted && !vm.isPlaying) ? 0.45 : 1)

                    Spacer()

                    if vm.isRecording && vm.pushToTalk {
                        HStack(spacing: 4) {
                            Text("Aa").font(.system(size: 12, weight: .semibold))
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(pttDragOffset > 40 ? Color.cAccent : Color.cTextTer)
                        .opacity(pttDragOffset > 10 ? min(1, Double(pttDragOffset - 10) / 50) : 0.3)
                        .frame(width: 60).transition(.opacity)
                    } else {
                        Color.clear.frame(width: 60, height: 40)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8)

                // Status + mode + effort row
                HStack(spacing: 8) {
                    Button { cycleInputMode() } label: {
                        Text(vm.typingMode ? "Typing" : "Voice")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.cTextSec)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Color.glass, in: Capsule())
                    }
                    if !vm.statusText.isEmpty {
                        let sc = statusColor
                        Text(vm.statusText)
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(sc)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(sc.opacity(0.12), in: Capsule())
                    }
                    Spacer()
                    if let s = vm.activeSession {
                        Menu {
                            ForEach(["low","medium","high"], id: \.self) { level in
                                Button { vm.sendEffort(level) } label: {
                                    HStack { Text(level.capitalized); if s.effort == level { Image(systemName: "checkmark") } }
                                }
                            }
                        } label: {
                            Image(systemName: effortIcon(s.effort))
                                .font(.system(size: 11)).foregroundStyle(Color.cTextSec)
                                .frame(width: 28, height: 28)
                                .background(Color.glass, in: Circle())
                                .overlay(Circle().strokeBorder(Color.glassBorder, lineWidth: 0.5))
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
            }
            .padding(.horizontal, 12).padding(.vertical, 10).padding(.bottom, 4)
            .background {
                if #available(iOS 26, *) {
                    Color.clear
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.ultraThinMaterial)
                }
            }
        }
        .padding(.horizontal, 8).padding(.bottom, 4)
    }

    // MARK: - Text Input Bar

    private var textInputBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button { cycleInputMode() } label: {
                    Text("Voice")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.cTextSec)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.glass, in: Capsule())
                }
                if !vm.statusText.isEmpty {
                    let sc = statusColor
                    Text(vm.statusText)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(sc)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(sc.opacity(0.12), in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)

            HStack(spacing: 10) {
                TextField("Message", text: $vm.typingText, axis: .vertical)
                    .textFieldStyle(.plain).font(.subheadline).lineLimit(1...5)
                    .foregroundStyle(Color.cText)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.glass, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.glassBorder, lineWidth: 0.5))
                    .onSubmit { vm.sendText() }.submitLabel(.send)

                Button { vm.sendText() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                        .foregroundStyle(
                            vm.typingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.cTextTer : Color.cAccent)
                }
                .disabled(vm.typingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
        .background {
            if #available(iOS 26, *) {
                Color.clear
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.ultraThinMaterial)
            }
        }
        .padding(.horizontal, 8).padding(.bottom, 4)
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
                Color.clear
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.ultraThinMaterial)
            }
        }
        .padding(.horizontal, 8).padding(.bottom, 4)
        .onAppear { pttTextFieldFocused = true }
    }

    // MARK: - Waveform

    private var waveformView: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(vm.audioLevels.enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.65 + Double(level) * 0.35))
                    .frame(width: 3, height: max(4, level * 32))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
        .frame(height: 36).frame(maxWidth: .infinity)
        .padding(.horizontal, 20).padding(.vertical, 6)
    }

    // MARK: - Mic Button

    private var micButtonVisual: some View {
        ZStack {
            // Pulsing glow ring during tap-to-record
            if vm.isRecording && !vm.pushToTalk {
                Circle()
                    .fill(micColor.opacity(0.18)).frame(width: 88, height: 88)
                    .scaleEffect(isPulsing ? 1.15 : 1.0)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isPulsing)
                Circle()
                    .strokeBorder(micColor.opacity(isPulsing ? 0.5 : 0.1), lineWidth: 1.5)
                    .frame(width: 88, height: 88)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isPulsing)
            }
            // Main button circle
            Circle()
                .fill(micColor)
                .frame(width: 68, height: 68)
                .shadow(color: micColor.opacity(0.5), radius: 16, y: 4)
            // Inner highlight
            Circle()
                .fill(LinearGradient(
                    colors: [.white.opacity(0.18), .clear],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 68, height: 68)
            Image(systemName: micIcon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 92, height: 92)
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
        return .cAccent
    }

    // MARK: - Helpers

    private var statusColor: Color {
        if vm.isRecording { return .cDanger }
        if vm.isPlaying   { return .cAccent }
        if vm.isProcessing || vm.activeSession?.isThinking == true { return .cWarning }
        return .cSuccess
    }

    private func cycleInputMode() { vm.inputMode = vm.typingMode ? "auto" : "typing" }

    private func effortIcon(_ e: String) -> String {
        switch e { case "low": "battery.25"; case "high": "bolt.fill"; default: "gauge.medium" }
    }
}

// MARK: - Scroll Bottom Detector

private struct ScrollBottomDetector: ViewModifier {
    @Binding var isAtBottom: Bool
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y >= geo.contentSize.height - geo.containerSize.height - 120
            } action: { _, atBottom in
                isAtBottom = atBottom
            }
        } else {
            content
        }
    }
}

// MARK: - Markdown Content View

private struct MarkdownContentView: View {
    let text: String
    let foreground: Color

    private enum Block {
        case text(String)
        case header(Int, String)
        case bullet(String)
        case numbered(String, String)
        case code(String, String)   // (language, content)
        case spacing
    }

    private func parse(_ raw: String) -> [Block] {
        var result: [Block] = []
        var lines  = raw.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            // Code fence
            if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i]); i += 1
                }
                if i < lines.count { i += 1 }
                result.append(.code(lang, codeLines.joined(separator: "\n")))
                continue
            }
            if line.hasPrefix("### ") { result.append(.header(3, String(line.dropFirst(4)))); i += 1; continue }
            if line.hasPrefix("## ")  { result.append(.header(2, String(line.dropFirst(3)))); i += 1; continue }
            if line.hasPrefix("# ")   { result.append(.header(1, String(line.dropFirst(2)))); i += 1; continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                result.append(.bullet(String(line.dropFirst(2)))); i += 1; continue
            }
            if let m = line.firstMatch(of: /^(\d+)\. (.+)/) {
                result.append(.numbered(String(m.output.1), String(m.output.2))); i += 1; continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if case .spacing? = result.last {} else { result.append(.spacing) }
                i += 1; continue
            }
            result.append(.text(line)); i += 1
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .spacing:
            Color.clear.frame(height: 3)

        case .text(let str):
            Text(LocalizedStringKey(str))
                .font(.system(size: 15))
                .foregroundStyle(foreground)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

        case .header(let level, let str):
            let sz: CGFloat = level == 1 ? 19 : level == 2 ? 16 : 14
            let wt: Font.Weight = level <= 2 ? .bold : .semibold
            Text(LocalizedStringKey(str))
                .font(.system(size: sz, weight: wt))
                .foregroundStyle(foreground)
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let str):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.cTextSec)
                    .frame(width: 10)
                Text(LocalizedStringKey(str))
                    .font(.system(size: 15))
                    .foregroundStyle(foreground)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .numbered(let num, let str):
            HStack(alignment: .top, spacing: 6) {
                Text("\(num).")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.cTextSec)
                    .frame(width: 22, alignment: .trailing)
                Text(LocalizedStringKey(str))
                    .font(.system(size: 15))
                    .foregroundStyle(foreground)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .code(let lang, let content):
            VStack(alignment: .leading, spacing: 0) {
                if !lang.isEmpty {
                    Text(lang)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.cTextTer)
                        .padding(.horizontal, 10).padding(.top, 7).padding(.bottom, 2)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(content)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.cText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, lang.isEmpty ? 10 : 0)
                        .padding(.bottom, 8)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.canvas2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.cBorder, lineWidth: 0.5))
        }
    }
}

// MARK: - Debug View

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

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var vm: ClawMuxViewModel
    @Environment(\.dismiss) var dismiss
    @State private var draftURL: String = ""

    var urlChanged: Bool { draftURL.trimmingCharacters(in: .whitespaces) != vm.serverURL.trimmingCharacters(in: .whitespaces) }
    var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—" }
    var appBuild:   String { Bundle.main.infoDictionary?["CFBundleVersion"]            as? String ?? "—" }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Server URL", text: $draftURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    if vm.isConnected && !urlChanged {
                        HStack(spacing: 6) {
                            Circle().fill(Color(.systemGreen)).frame(width: 8, height: 8)
                            Text("Connected").font(.subheadline).foregroundStyle(Color(.systemGreen))
                        }
                    } else {
                        Button("Connect") {
                            vm.serverURL = draftURL.trimmingCharacters(in: .whitespaces)
                            vm.connect(); dismiss()
                        }
                        .disabled(draftURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("e.g. workstation.tailee9084.ts.net:3460").font(.caption).foregroundStyle(.secondary)
                }
                .onAppear { draftURL = vm.serverURL }

                if vm.activeSessionId != nil {
                    Section("Active Session") {
                        Picker("Speed", selection: Binding(get: { vm.activeSpeed }, set: { vm.activeSpeed = $0 })) {
                            ForEach(SPEED_OPTIONS, id: \.value) { Text($0.label).tag($0.value) }
                        }
                    }
                }

                Section("Global") {
                    Toggle("Haptics", isOn: $vm.globalHaptics)
                        .onChange(of: vm.globalHaptics) { _, on in
                            vm.hapticsRecordingAuto = on; vm.hapticsPlaybackAuto = on; vm.hapticsSessionAuto = on
                            vm.hapticsRecordingPTT  = on; vm.hapticsPlaybackPTT  = on; vm.hapticsSessionPTT  = on
                            vm.hapticsSend = on; vm.hapticsSessionTyping = on
                        }
                    Toggle("Sounds", isOn: $vm.globalSounds)
                        .onChange(of: vm.globalSounds) { _, on in
                            vm.soundThinkingAuto = on; vm.soundListeningAuto = on; vm.soundProcessingAuto = on
                            vm.soundReadyAuto = on; vm.soundThinkingPTT = on; vm.soundReadyPTT = on
                        }
                    Toggle("Notifications", isOn: $vm.globalNotifications)
                        .onChange(of: vm.globalNotifications) { _, on in
                            vm.notifyAuto = on; vm.notifyPTT = on; vm.notifyTyping = on
                        }
                }

                Section("Voice") {
                    Toggle("Auto Record", isOn: $vm.autoRecord)
                    Toggle("Thinking Sounds", isOn: $vm.soundThinkingAuto)
                    Toggle("Listening Cue", isOn: $vm.soundListeningAuto)
                }

                Section { Toggle("Voice Responses", isOn: $vm.voiceResponses)
                    .onChange(of: vm.voiceResponses) { _, v in vm.updateSetting("voice_responses", value: v) }
                } footer: { Text("When off, the agent responds with text only — no speech.") }

                Section {
                    Toggle("Verbose Activity Log", isOn: $vm.verboseMode)
                } header: { Text("Chat") } footer: {
                    Text("Show agent tool use and system messages in chat. Off = minimal mode, only user and assistant messages.")
                }

                Section {
                    Toggle("Background Mode", isOn: $vm.backgroundMode)
                } header: { Text("Background") } footer: {
                    Text(vm.backgroundMode
                         ? "Voice sessions stay alive when the app is backgrounded using a silent audio loop."
                         : "The WebSocket connection may drop when the app is backgrounded.")
                }

                if vm.usage5hPct != nil || vm.usage7dPct != nil {
                    Section("Usage") {
                        if let pct = vm.usage5hPct {
                            HStack {
                                Text("5-hour window"); Spacer()
                                VStack(alignment: .trailing) {
                                    Text("\(pct)%").font(.subheadline.bold())
                                        .foregroundStyle(pct >= 80 ? Color(.systemRed) : pct >= 60 ? Color(.systemOrange) : Color(.systemGreen))
                                    if let r = vm.usage5hReset { Text("resets in \(r)").font(.caption2).foregroundStyle(.tertiary) }
                                }
                            }
                        }
                        if let pct = vm.usage7dPct {
                            HStack {
                                Text("7-day window"); Spacer()
                                VStack(alignment: .trailing) {
                                    Text("\(pct)%").font(.subheadline.bold())
                                        .foregroundStyle(pct >= 80 ? Color(.systemRed) : pct >= 60 ? Color(.systemOrange) : Color(.systemGreen))
                                    if let r = vm.usage7dReset { Text("resets in \(r)").font(.caption2).foregroundStyle(.tertiary) }
                                }
                            }
                        }
                        Button { UIImpactFeedbackGenerator(style: .light).impactOccurred(); vm.fetchUsage() } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                }

                Section("Debug") {
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            vm.showDebug = true; vm.startDebugRefresh()
                        }
                    } label: { Label("Open Debug Panel", systemImage: "ant") }
                }

                Section {
                    HStack { Text("Version"); Spacer(); Text(appVersion).foregroundStyle(.secondary).font(.system(.subheadline, design: .monospaced)) }
                    HStack { Text("Build");   Spacer(); Text(appBuild).foregroundStyle(.secondary).font(.system(.subheadline, design: .monospaced)) }
                } footer: {
                    Text("ClawMux").frame(maxWidth: .infinity, alignment: .center)
                        .font(.caption2).foregroundStyle(.tertiary).padding(.top, 4)
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Auto Mode Settings

struct AutoModeSettingsView: View {
    @ObservedObject var vm: ClawMuxViewModel
    var body: some View {
        Form {
            Section {
                Toggle("Auto Record", isOn: $vm.autoRecord).onChange(of: vm.autoRecord) { _, v in vm.updateSetting("auto_record", value: v) }
                Toggle("Voice Detection (VAD)", isOn: $vm.vadEnabled).onChange(of: vm.vadEnabled) { _, v in vm.updateSetting("auto_end", value: v) }
                Toggle("Auto Interrupt", isOn: $vm.autoInterrupt).onChange(of: vm.autoInterrupt) { _, v in vm.updateSetting("auto_interrupt", value: v) }
                Toggle("Record While Thinking", isOn: $vm.allowRecordWhileThinking)
            } header: { Text("Input") } footer: { Text("Mic opens automatically after the agent speaks.") }

            if vm.vadEnabled {
                Section {
                    Picker("Stop After", selection: $vm.vadSilenceDuration) {
                        Text("0.5 s").tag(0.5); Text("1 s").tag(1.0); Text("1.5 s").tag(1.5)
                        Text("2 s").tag(2.0); Text("3 s").tag(3.0); Text("4 s").tag(4.0); Text("5 s").tag(5.0)
                    }
                    Picker("Silence Cutoff", selection: $vm.vadThreshold) {
                        Text("Sensitive (quiet room)").tag(5.0)
                        Text("Normal").tag(10.0)
                        Text("Relaxed (noisy room)").tag(20.0)
                    }
                } header: { Text("VAD Tuning") } footer: {
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
            Section { Toggle("Notifications", isOn: $vm.notifyAuto) } footer: {
                Text("Notify when the agent responds while the app is in the background.")
            }
            Section { Toggle("Live Activity", isOn: $vm.liveActivityAuto) } footer: {
                Text("Show session status on Dynamic Island and Lock Screen.")
            }
        }
        .navigationTitle("Auto Mode").navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - PTT Mode Settings

struct PTTModeSettingsView: View {
    @ObservedObject var vm: ClawMuxViewModel
    var body: some View {
        Form {
            Section {
                Toggle("Record While Thinking", isOn: $vm.allowRecordWhileThinking)
            } header: { Text("Input") } footer: {
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
            Section { Toggle("Notifications", isOn: $vm.notifyPTT) } footer: {
                Text("Notify when the agent responds while the app is in the background.")
            }
            Section { Toggle("Live Activity", isOn: $vm.liveActivityPTT) } footer: {
                Text("Show session status on Dynamic Island and Lock Screen.")
            }
        }
        .navigationTitle("Push to Talk").navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Typing Mode Settings

struct TypingModeSettingsView: View {
    @ObservedObject var vm: ClawMuxViewModel
    var body: some View {
        Form {
            Section("Haptics") {
                Toggle("Send Message", isOn: $vm.hapticsSend)
                Toggle("Session Events", isOn: $vm.hapticsSessionTyping)
            }
            Section { Toggle("Notifications", isOn: $vm.notifyTyping) } footer: {
                Text("Notify when the agent responds while the app is in the background.")
            }
            Section {
                Text("No Live Activity in typing mode. Notifications are used instead.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
        }
        .navigationTitle("Typing").navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Color Hex

extension Color {
    init(hex: UInt) {
        self.init(
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8)  & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255
        )
    }
}
