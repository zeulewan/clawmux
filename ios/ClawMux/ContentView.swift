import SwiftUI
import UniformTypeIdentifiers

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
    static let cSuccess    = Color(hex: 0x30D158)   // browser --green
    static let cWarning    = Color(hex: 0xFF9F0A)   // browser --orange
    static let cCaution    = Color(hex: 0xFFD60A)   // browser --yellow (starting/connecting)
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

private func voiceIdByName(_ name: String) -> String {
    ALL_VOICES.first { $0.name.lowercased() == name.lowercased() }?.id ?? name.lowercased()
}

private func voiceIcon(_ id: String) -> String {
    switch id {
    // Project 1
    case "af_sky":      return "cloud.fill"
    case "af_alloy":    return "diamond.fill"
    case "af_nova":     return "star.fill"
    case "af_sarah":    return "heart.fill"
    case "am_adam":     return "paperplane.fill"
    case "am_echo":     return "waveform"
    case "am_eric":     return "chart.line.uptrend.xyaxis"
    case "am_onyx":     return "shield.fill"
    case "bm_fable":    return "book.fill"
    // Project 2
    case "af_bella":    return "info.circle.fill"
    case "af_jessica":  return "checkmark.circle.fill"
    case "af_heart":    return "heart.fill"
    case "am_michael":  return "shield.lefthalf.filled"
    case "am_liam":     return "chevron.left.forwardslash.chevron.right"
    case "am_fenrir":   return "globe"
    case "bf_emma":     return "envelope.fill"
    case "bm_george":   return "doc.fill"
    case "bm_daniel":   return "music.note"
    // Project 3
    case "af_aoede":    return "music.note.list"
    case "af_jadzia":   return "figure.walk"
    case "af_kore":     return "target"
    case "af_nicole":   return "heart.fill"
    case "af_river":    return "water.waves"
    case "am_puck":     return "face.smiling.fill"
    case "bf_alice":    return "bookmark.fill"
    case "bf_lily":     return "leaf.fill"
    case "bm_lewis":    return "checklist"
    default:            return "mic.fill"
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
    @State private var sidebarExpanded:        Bool = false
    @State private var showFilePicker:         Bool = false
    @State private var showCreateGroupChat     = false
    @State private var newGroupChatName        = ""
    @State private var voiceTintColor: Color   = .clear  // stable tint, updated via onChange only

    var body: some View {
        // Body + Sidebar ZStack — header floats above as safeAreaInset so content scrolls behind it
        ZStack(alignment: .leading) {
            // Content offset 48px right so messages/input bars never go under collapsed sidebar
            mainAreaView
                .padding(.leading, 48)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Dim overlay behind expanded sidebar (starts at sidebar edge)
            if sidebarExpanded {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .padding(.leading, 48)
                    .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { sidebarExpanded = false } }
                    .transition(.opacity)
            }

            // Sidebar glass overlay — floats over content edge for proper blur
            sidebarStripView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Header as overlay: floats above content so messages scroll behind the glass bar
        .overlay(alignment: .top) {
            topBarView
        }
        .overlay(alignment: .bottomTrailing) {
            Text("build-\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.4))
                .padding(6)
                .allowsHitTesting(false)
        }
        .background(Color.canvas1.ignoresSafeArea())
        .preferredColorScheme(.dark)
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
                welcomeView
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
    }

    // MARK: - Group Chat View

    private var groupChatMainView: some View {
        groupChatScrollArea
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) { textInputBar }
    }

    private var groupChatHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.cAccent)
            Text(vm.activeGroupName ?? "Group Chat")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.cText)
                .lineLimit(1)
            Spacer()
            let dotColor: Color = vm.isConnected ? .cSuccess : vm.isConnecting ? .cCaution : .cDanger
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .padding(6)
                .background(Color.glass, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.glassBorder, lineWidth: 0.5))
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background {
            if #available(iOS 26, *) {
                Color.clear.glassEffect(.regular, in: .rect).ignoresSafeArea(edges: .top)
            } else {
                Color.clear.background(.ultraThinMaterial).ignoresSafeArea(edges: .top)
            }
        }
    }

    private var groupChatScrollArea: some View {
        ZStack {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(vm.groupMessages.enumerated()), id: \.element.id) { idx, msg in
                            groupMessageBubble(msg, isLast: idx == vm.groupMessages.count - 1)
                        }
                        Color.clear.frame(height: 16).id("gc-bottom")
                    }
                    .padding(.horizontal, 12).padding(.top, 64).padding(.bottom, 8)
                }
                .onChange(of: vm.groupMessages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo("gc-bottom", anchor: .bottom)
                    }
                }
                .onAppear {
                    // Re-fetch history every time view appears (catches race where fetch completed before view was ready)
                    if let name = vm.activeGroupName { vm.fetchGroupHistory(groupName: name) }
                    proxy.scrollTo("gc-bottom", anchor: .bottom)
                }
            }
            // Empty state
            if vm.groupMessages.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 32, weight: .thin))
                        .foregroundStyle(Color.cTextTer)
                    Text("No messages yet")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.cTextSec)
                    Text("Start the conversation below")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.cTextTer)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func groupMessageBubble(_ msg: GroupChatMessage, isLast: Bool) -> some View {
        let isUser = msg.role == "user" && msg.sender.isEmpty
        let color = isUser ? Color.clear : voiceColor(msg.sender)
        let senderLabel = isUser ? nil : (ALL_VOICES.first { $0.id == msg.sender }?.name ?? msg.sender)

        let shape = UnevenRoundedRectangle(
            topLeadingRadius: isUser ? 18 : 4,
            bottomLeadingRadius: 18,
            bottomTrailingRadius: isUser ? 4 : 18,
            topTrailingRadius: 18,
            style: .continuous)

        return HStack(alignment: .bottom, spacing: 0) {
            if isUser { Spacer(minLength: 56) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
                // Sender label for agent messages
                if let label = senderLabel {
                    Text(label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 4)
                }
                // Message bubble
                MarkdownContentView(text: msg.text, foreground: Color.cText,
                                    fontSize: CGFloat(vm.chatFontSize))
                    .padding(.horizontal, isUser ? 12 : 14)
                    .padding(.vertical, 8)
                    .background(shape.fill(isUser ? Color.cAccent.opacity(0.18) : Color.cCard))
                    .overlay(shape.fill(isUser ? Color.clear : color.opacity(0.20)))
                    .overlay(shape.strokeBorder(
                        isUser ? Color.clear : Color(hex: 0x2A3A52), lineWidth: 1))
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = msg.text
                            withAnimation { showCopiedToast = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                withAnimation { showCopiedToast = false }
                            }
                        } label: { Label("Copy", systemImage: "doc.on.doc") }
                    }
                // Timestamp on last message
                if isLast {
                    Text(shortTime(Date(timeIntervalSince1970: msg.ts)))
                        .font(.system(size: 9))
                        .foregroundStyle(Color.cTextTer)
                        .padding(.horizontal, 4)
                }
            }
            if !isUser { Spacer(minLength: 56) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    // MARK: - Sidebar (collapsible, 48px → 220px, overlays main when expanded)

    private var sidebarStripView: some View {
        // Agent list — icons when collapsed, full cards when expanded
        ScrollViewReader { sidebarProxy in
        ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: sidebarExpanded ? 2 : 1) {
                    Color.clear.frame(height: 0).id("sidebar-top")
                    if sidebarExpanded {
                        // Agents first (matches mobile web — group chats section is below agents)
                        let groups = projectGroups
                        ForEach(groups.namedProjects, id: \.self) { project in
                            let voices = groups.byProject[project] ?? []
                            projectSection(project, voices: voices)
                        }
                        if !groups.ungrouped.isEmpty {
                            if !groups.namedProjects.isEmpty {
                                HStack {
                                    Text("AGENTS")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Color.cTextTer)
                                        .tracking(0.8)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, 8).padding(.bottom, 2)
                            }
                            VStack(spacing: 2) {
                                ForEach(groups.ungrouped) { voice in agentCard(voice) }
                            }
                            .padding(.horizontal, 8)
                        }

                        // Group chats section below agents — matches web sidebar-gc-section placement
                        let chatGroups = activeGroups
                        if !chatGroups.isEmpty {
                            HStack {
                                Text("GROUP CHATS")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.cTextTer)
                                    .tracking(0.8)
                                Spacer()
                                Button {
                                    newGroupChatName = ""
                                    showCreateGroupChat = true
                                } label: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.cTextSec)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 8).padding(.bottom, 2)
                            ForEach(chatGroups, id: \.groupId) { g in
                                groupCard(g.groupId, name: g.name, voices: g.voices)
                            }
                        }
                    } else {
                        // Collapsed: all agent icons, then group icons at bottom
                        ForEach(ALL_VOICES) { voice in
                            sidebarIcon(for: voice)
                        }
                        let chatGroups = activeGroups
                        ForEach(chatGroups, id: \.groupId) { g in
                            groupIcon(g.groupId, voices: g.voices)
                        }
                    }
                }
                .padding(.vertical, 4)
        }
        .accessibilityIdentifier("SidebarScrollView")
        // Tray in .safeAreaInset: completely separate view layer — eliminates
        // hit-test overlap between ScrollView icon buttons and the hamburger
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                // Matches web #sidebar-tray: expand-btn(48px) + notes-btn(flex) + settings-btn(flex)
                Color.cBorder.opacity(0.5).frame(height: 0.5)
                HStack(spacing: 0) {
                    // Hamburger — always 48px, border-right matches web #sidebar-expand-btn
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            sidebarExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 22))  // web: font-size 1.4rem ≈ 22pt
                            .foregroundStyle(Color.cTextSec)
                            .frame(width: 48, height: 52)
                    }
                    .accessibilityIdentifier("HamburgerButton")
                    .overlay(alignment: .trailing) {
                        Color.cBorder.frame(width: 0.5)  // web: border-right: 1px solid var(--border)
                    }
                    // Notes + Settings — visible only when expanded (clipped otherwise)
                    if sidebarExpanded {
                        Button {
                            vm.showNotes = true
                            withAnimation(.spring(response: 0.3)) { sidebarExpanded = false }
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: "note.text").font(.system(size: 13))
                                Text("Notes").font(.system(size: 10, weight: .medium))  // web: 0.6rem ≈ 10pt
                            }
                            .foregroundStyle(Color.cTextSec)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .accessibilityIdentifier("SidebarNotesButton")
                        Button {
                            vm.showSettings = true
                            withAnimation(.spring(response: 0.3)) { sidebarExpanded = false }
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: "gearshape.fill").font(.system(size: 13))
                                Text("Settings").font(.system(size: 10, weight: .medium))  // web: 0.6rem ≈ 10pt
                            }
                            .foregroundStyle(Color.cTextSec)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .accessibilityIdentifier("SidebarSettingsButton")
                    }
                }
                .frame(height: 52)
                Color.clear.frame(height: 34)  // home indicator safe area
            }
            .background {
                if #available(iOS 26, *) {
                    Color.clear.glassEffect(.regular, in: .rect)
                } else {
                    Color(red: 0.04, green: 0.05, blue: 0.09).opacity(0.92)
                }
            }
        }
        .frame(width: sidebarExpanded ? 220 : 48)
        .frame(maxHeight: .infinity)
        .ignoresSafeArea(edges: .bottom)
        .background {
            if #available(iOS 26, *) {
                Color.clear.glassEffect(.regular, in: .rect).ignoresSafeArea(edges: .bottom)
            } else {
                Color(red: 0.04, green: 0.05, blue: 0.09).opacity(0.92).ignoresSafeArea(edges: .bottom)
            }
        }
        .overlay(alignment: .trailing) {
            Color.cBorder.opacity(0.6).frame(width: 0.5)
        }
        .onChange(of: sidebarExpanded) { expanded in
            if !expanded { withAnimation { sidebarProxy.scrollTo("sidebar-top", anchor: .top) } }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: sidebarExpanded)
        .clipped()
        } // ScrollViewReader
    }

    private func sidebarIcon(for voice: VoiceInfo) -> some View {
        let session   = vm.sessions.first { $0.voice == voice.id }
        let spawning  = vm.spawningVoiceIds.contains(voice.id)
        let isSelected = !vm.isFocusMode && vm.activeSession?.voice == voice.id
        let color     = voiceColor(voice.id)
        let alive     = session != nil || spawning
        let rc        = ringColor(session, spawning: spawning)
        let thinking  = session?.isThinking == true
        let hasUnread = (session?.unreadCount ?? 0) > 0
        let inGroup   = !(session?.groupId ?? "").isEmpty

        return Button {
            if let s = session {
                vm.switchToSession(s.id)
            } else if !spawning {
                vm.spawnSession(voiceId: voice.id)
            }
            withAnimation(.spring(response: 0.3)) { sidebarExpanded = false }
        } label: {
            ZStack {
                // Selected background tint
                if isSelected { Color.cAccent.opacity(0.08) }

                // Avatar (centered)
                ZStack {
                    if thinking {
                        Circle()
                            .strokeBorder(color.opacity(isPulsing ? 0.45 : 0.05), lineWidth: 5)
                            .frame(width: 34, height: 34)
                            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isPulsing)
                    }
                    Circle()
                        .fill(color.opacity(alive ? 0.15 : 0.06))
                        .frame(width: 28, height: 28)
                    if alive {
                        Circle()
                            .strokeBorder(rc, lineWidth: 1.5)
                            .frame(width: 28, height: 28)
                    }
                    Image(systemName: voiceIcon(voice.id))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(alive ? color : color.opacity(0.25))
                    if hasUnread {
                        Circle()
                            .fill(Color.cDanger)
                            .frame(width: 7, height: 7)
                            .offset(x: 9, y: -9)
                    }
                    // ⬡ group badge — bottom-right, blue, matches web .sb-group-badge
                    if inGroup {
                        Text("⬡")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color(hex: 0x0A84FF))
                            .offset(x: 9, y: 9)
                    }
                }

                // Left accent bar for selected state
                if isSelected {
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.cAccent)
                            .frame(width: 3)
                            .padding(.vertical, 10)
                            .shadow(color: Color.cAccent.opacity(0.5), radius: 3)
                        Spacer()
                    }
                }
            }
            .frame(width: 48, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            // Launch Session — only when no session (matches web ctx-launch)
            if session == nil {
                Button { vm.spawnSession(voiceId: voice.id) } label: {
                    Label("Launch Session", systemImage: "play.circle")
                }
            }
            // Mark as Unread / Read — matches web ctx-mark-unread / ctx-mark-read
            if let s = session {
                if s.unreadCount == 0 {
                    Button { vm.markSessionUnread(s.id) } label: {
                        Label("Mark as Unread", systemImage: "envelope.badge")
                    }
                } else {
                    Button { vm.clearSessionUnread(s.id) } label: {
                        Label("Mark as Read", systemImage: "checkmark.circle")
                    }
                }
            }
            // Set Role — matches web ctx-set-role submenu
            if let s = session {
                Menu {
                    ForEach(["Manager", "Frontend", "Backend", "Researcher", "Worker"], id: \.self) { role in
                        Button {
                            vm.setSessionRole(s.id, role: role)
                        } label: {
                            if s.role.lowercased() == role.lowercased() {
                                Label(role, systemImage: "checkmark")
                            } else {
                                Text(role)
                            }
                        }
                    }
                } label: {
                    Label("Set Role", systemImage: "person.badge.key")
                }
            }
            // Move to Project — matches web ctx-move-project submenu
            if let s = session, !vm.knownProjects.isEmpty {
                Menu {
                    ForEach(vm.knownProjects, id: \.self) { proj in
                        Button {
                            vm.moveSessionToProject(s.id, project: proj)
                        } label: {
                            if s.project == proj {
                                Label(proj, systemImage: "checkmark")
                            } else {
                                Text(proj)
                            }
                        }
                    }
                } label: {
                    Label("Move to Project", systemImage: "folder")
                }
            }
            // Add to Group Chat — matches web ctx-add-group submenu
            if session != nil && !vm.knownGroupChats.isEmpty {
                Menu {
                    ForEach(vm.knownGroupChats, id: \.name) { gc in
                        let isMember = gc.voices.contains(voice.id)
                        Button {
                            vm.toggleGroupChatMember(voiceId: voice.id, groupName: gc.name, isMember: isMember)
                        } label: {
                            if isMember { Label(gc.name, systemImage: "checkmark") }
                            else { Text(gc.name) }
                        }
                    }
                } label: {
                    Label("Add to Group Chat", systemImage: "bubble.left.and.bubble.right")
                }
            }
            // Reset — matches web ctx-reset
            Button(role: .destructive) { resetVoiceId = voice.id; showResetConfirm = true } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            // Disband Group Chat — matches web ctx-disband-group
            if let s = session, !s.groupId.isEmpty {
                Button(role: .destructive) { vm.disbandGroup(s.groupId) } label: {
                    Label("Disband Group Chat", systemImage: "person.2.slash")
                }
            }
            // Terminate Session — matches web ctx-terminate
            if let s = session {
                Button(role: .destructive) { vm.terminateSession(s.id) } label: {
                    Label("Terminate Session", systemImage: "xmark.circle")
                }
            }
        }
    }

    // MARK: - Welcome View (shown when no session is active)

    private var welcomeView: some View {
        VStack(spacing: 0) {
            // Welcome content — matches web #welcome-view: icon + title + subtitle
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.cCard)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.cBorder, lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
                        .frame(width: 60, height: 60)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.cAccent)
                }
                .padding(.bottom, 4)

                Text("ClawMux")
                    .font(.system(size: 18, weight: .bold))
                    .kerning(-0.36)
                    .foregroundStyle(Color.cTextSec)

                if vm.isConnected {
                    Text("Select an agent to begin")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.cTextTer)
                } else {
                    Text(vm.serverURL.isEmpty ? "Tap Settings to configure server" : "Connecting…")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.cTextTer)
                    Button { vm.showSettings = true } label: {
                        Label("Settings", systemImage: "gearshape.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.cText)
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .background(Color.cCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.cBorder, lineWidth: 1))
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 32).padding(.bottom, 24)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    let groups = projectGroups
                    ForEach(groups.namedProjects, id: \.self) { project in
                        projectSection(project, voices: groups.byProject[project] ?? [])
                    }
                    if !groups.ungrouped.isEmpty {
                        if !groups.namedProjects.isEmpty {
                            HStack {
                                Text("AGENTS")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.cTextTer)
                                    .tracking(0.8)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 12).padding(.bottom, 4)
                        }
                        VStack(spacing: 2) {
                            ForEach(groups.ungrouped) { voice in agentCard(voice) }
                        }
                        .padding(.horizontal, 8)
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
                .padding(.horizontal, 16)
                .padding(.top, 8).padding(.bottom, 4)
            }
            .buttonStyle(.plain)

            if !collapsed {
                VStack(spacing: 2) {
                    ForEach(voices) { voice in agentCard(voice) }
                }
                .padding(.horizontal, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Group Chat Card (mirrors web .sidebar-group-card)

    private var activeGroups: [(groupId: String, name: String?, voices: [VoiceInfo])] {
        var byGroup: [String: [String]] = [:]
        for s in vm.sessions where !s.groupId.isEmpty {
            if !(byGroup[s.groupId, default: []].contains(s.voice)) {
                byGroup[s.groupId, default: []].append(s.voice)
            }
        }
        return byGroup.map { gid, voiceIds in
            let voices = ALL_VOICES.filter { voiceIds.contains($0.id) }
            return (gid, vm.groupName(for: gid), voices)
        }.sorted { $0.groupId < $1.groupId }
    }

    @ViewBuilder
    private func groupCard(_ groupId: String, name: String? = nil, voices: [VoiceInfo]) -> some View {
        let blue = Color(hex: 0x0A84FF)
        let isSelected = !vm.isFocusMode && vm.activeGroupName == (name ?? groupId)
        VStack(spacing: 0) {
            // Header — tap to enter group chat mode
            Button {
                let firstName = name ?? groupId
                var firstSid: String? = nil
                for v in voices {
                    if let s = vm.sessions.first(where: { $0.voice == v.id && !$0.isDead }) {
                        firstSid = s.id
                        break
                    }
                }
                vm.switchToGroupChat(name: firstName, firstSessionId: firstSid)
                withAnimation(.spring(response: 0.3)) { sidebarExpanded = false }
            } label: {
                HStack(spacing: 8) {
                    // Stacked avatar circles — up to 4, -6px overlap (mirrors .sg-avatar)
                    ZStack(alignment: .leading) {
                        ForEach(Array(voices.prefix(4).enumerated()), id: \.offset) { i, v in
                            Circle()
                                .fill(voiceColor(v.id))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(Color.canvas2, lineWidth: 1.5))
                                .offset(x: CGFloat(i) * 16)
                        }
                    }
                    .frame(width: 22 + CGFloat(max(min(voices.count, 4) - 1, 0)) * 16, height: 22)

                    // Info VStack: group name + member names (mirrors .gc-name + .gc-members-text)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name ?? "GROUP CHAT")
                            .font(.system(size: name != nil ? 12 : 8, weight: name != nil ? .semibold : .bold))
                            .tracking(name != nil ? 0 : 0.5)
                            .foregroundStyle(name != nil ? Color.cText : blue.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(voices.map { $0.name }.joined(separator: ", "))
                            .font(.system(size: 11))
                            .foregroundStyle(Color.cTextSec)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // × Disband button (mirrors .sg-disband)
                    Button {
                        vm.disbandGroup(groupId)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.cTextSec)
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("GroupChatCard-\(groupId)")

        }
        .background(blue.opacity(isSelected ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(blue.opacity(0.35), lineWidth: 1))
        // Left 3px inset bar when selected — mirrors web .sidebar-group-card.selected box-shadow: inset 3px 0 0 blue
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(blue)
                    .frame(width: 3)
                    .padding(.vertical, 8)
                    .padding(.leading, 1)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
    }

    // Compact group icon for collapsed sidebar — stacked avatars in 48px strip
    @ViewBuilder
    private func groupIcon(_ groupId: String, voices: [VoiceInfo]) -> some View {
        let blue = Color(hex: 0x0A84FF)
        let groupName = vm.groupName(for: groupId) ?? groupId
        Button {
            var firstSid: String? = nil
            for v in voices {
                if let s = vm.sessions.first(where: { $0.voice == v.id && !$0.isDead }) {
                    firstSid = s.id
                    break
                }
            }
            vm.switchToGroupChat(name: groupName, firstSessionId: firstSid)
        } label: {
            ZStack {
                let shown = Array(voices.prefix(3))
                ZStack(alignment: .leading) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { i, v in
                        Circle()
                            .fill(voiceColor(v.id))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(Color.canvas2, lineWidth: 1))
                            .offset(x: CGFloat(i) * 11)
                    }
                }
                .frame(width: 16 + CGFloat(max(shown.count - 1, 0)) * 11, height: 16)
            }
            .frame(width: 48, height: 44)
            .background(blue.opacity(0.07))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("GroupChatIcon-\(groupId)")
    }

    private func agentCard(_ voice: VoiceInfo) -> some View {
        let session    = vm.sessions.first { $0.voice == voice.id }
        let spawning   = vm.spawningVoiceIds.contains(voice.id)
        let isSelected = !vm.isFocusMode && vm.activeSession?.voice == voice.id
        let color      = voiceColor(voice.id)
        let alive      = session != nil || spawning
        let thinking   = session?.isThinking == true
        let rc         = ringColor(session, spawning: spawning)

        let dotPulsing = thinking || spawning || session?.state == .starting || session?.state == .compacting

        return Button {
            if let s = session {
                vm.switchToSession(s.id)
            } else if !spawning {
                vm.spawnSession(voiceId: voice.id)
            }
            withAnimation(.spring(response: 0.3)) { sidebarExpanded = false }
        } label: {
            HStack(spacing: 8) {
                // sb-icon: 34px circle with 2px state-color border + glow (hub.html .sb-icon 34×34)
                ZStack {
                    Circle()
                        .fill(color.opacity(alive ? 0.15 : 0.06))
                    Circle()
                        .strokeBorder(alive ? rc : Color.clear, lineWidth: 2)
                        .shadow(color: rc.opacity(alive ? (dotPulsing ? (isPulsing ? 0.5 : 0.1) : 0.35) : 0), radius: 4)
                        .animation(dotPulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: isPulsing)
                    Image(systemName: voiceIcon(voice.id))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(alive ? color : color.opacity(0.30))
                }
                .frame(width: 34, height: 34)

                // sb-info: name + area + role + task + status (hub.html hierarchy)
                // This VStack starts at x=50 (8pad+32icon+10gap) — clipped at 48px when collapsed
                VStack(alignment: .leading, spacing: 1) {
                    Text(voice.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(alive ? color : Color.cTextTer)
                        .lineLimit(1)
                    if let s = session, alive {
                        if !s.projectArea.isEmpty {
                            Text(s.projectArea.uppercased())
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Color(hex: 0x0A84FF).opacity(0.75))
                                .tracking(0.5)
                                .lineLimit(1)
                        }
                        if !s.role.isEmpty {
                            Text(s.role.uppercased())
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.cTextTer)
                                .tracking(0.6)
                                .lineLimit(1)
                        }
                        if !s.task.isEmpty {
                            Text(s.task)
                                .font(.system(size: 9))
                                .foregroundStyle(Color.cTextSec.opacity(0.8))
                                .lineLimit(2).truncationMode(.tail)
                        }
                    }
                    // sb-status: dot + text (hub.html .sb-dot + .sb-status)
                    HStack(alignment: .center, spacing: 4) {
                        Circle()
                            .fill(rc)
                            .frame(width: 6, height: 6)
                            .shadow(color: rc.opacity(alive ? 0.5 : 0), radius: 2)
                            .scaleEffect(dotPulsing && isPulsing ? 1.15 : dotPulsing ? 0.7 : 1.0)
                            .opacity(dotPulsing && isPulsing ? 1.0 : dotPulsing ? 0.15 : 1.0)
                            .animation(dotPulsing ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: isPulsing)
                        Text(cardStatus(session, spawning: spawning))
                            .font(.system(size: 9))
                            .foregroundStyle(alive ? Color.cTextSec : Color.cTextTer)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                // Badges (right side)
                VStack(spacing: 4) {
                    if let u = session?.unreadCount, u > 0 {
                        Text("\(u)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(Color.cDanger, in: Circle())
                    }
                    if let s = session, !s.groupId.isEmpty {
                        Text("⬡")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color(hex: 0x0A84FF))
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack(alignment: .leading) {
                    // Selected bg: matches web .sidebar-card.selected { background: var(--selected-bg) }
                    if isSelected {
                        Color(.systemPurple).opacity(0.08)
                    }
                    // Left accent bar: 3px × 55% height purple (hub.html .selected::before)
                    if isSelected {
                        Capsule()
                            .fill(Color(.systemPurple))
                            .frame(width: 3, height: 26)
                            .shadow(color: Color(.systemPurple).opacity(0.6), radius: 3)
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if session == nil {
                Button { vm.spawnSession(voiceId: voice.id) } label: {
                    Label("Launch Session", systemImage: "play.circle")
                }
            }
            if let s = session {
                if s.unreadCount == 0 {
                    Button { vm.markSessionUnread(s.id) } label: {
                        Label("Mark as Unread", systemImage: "envelope.badge")
                    }
                } else {
                    Button { vm.clearSessionUnread(s.id) } label: {
                        Label("Mark as Read", systemImage: "checkmark.circle")
                    }
                }
                Menu {
                    ForEach(["Manager", "Frontend", "Backend", "Researcher", "Worker"], id: \.self) { role in
                        Button { vm.setSessionRole(s.id, role: role) } label: {
                            if s.role.lowercased() == role.lowercased() { Label(role, systemImage: "checkmark") }
                            else { Text(role) }
                        }
                    }
                } label: { Label("Set Role", systemImage: "person.badge.key") }
                if !vm.knownProjects.isEmpty {
                    Menu {
                        ForEach(vm.knownProjects, id: \.self) { proj in
                            Button { vm.moveSessionToProject(s.id, project: proj) } label: {
                                if s.project == proj { Label(proj, systemImage: "checkmark") }
                                else { Text(proj) }
                            }
                        }
                    } label: { Label("Move to Project", systemImage: "folder") }
                }
                if !vm.knownGroupChats.isEmpty {
                    Menu {
                        ForEach(vm.knownGroupChats, id: \.name) { gc in
                            let isMember = gc.voices.contains(voice.id)
                            Button {
                                vm.toggleGroupChatMember(voiceId: voice.id, groupName: gc.name, isMember: isMember)
                            } label: {
                                if isMember { Label(gc.name, systemImage: "checkmark") }
                                else { Text(gc.name) }
                            }
                        }
                    } label: { Label("Add to Group Chat", systemImage: "bubble.left.and.bubble.right") }
                }
                if !s.groupId.isEmpty {
                    Button(role: .destructive) { vm.disbandGroup(s.groupId) } label: {
                        Label("Disband Group Chat", systemImage: "person.2.slash")
                    }
                }
                Button(role: .destructive) { vm.terminateSession(s.id) } label: {
                    Label("Terminate Session", systemImage: "xmark.circle")
                }
            }
            Button(role: .destructive) { resetVoiceId = voice.id; showResetConfirm = true } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
        }
    }

    private func ringColor(_ session: VoiceSession?, spawning: Bool) -> Color {
        if spawning { return .cCaution }                  // yellow: starting up
        guard let s = session else { return .cTextTer }  // offline: var(--text-tertiary)
        if s.state == .starting { return .cCaution }      // yellow: starting
        if s.unreadCount > 0   { return .cDanger }        // red: unread
        if s.state == .compacting { return .cCaution }    // yellow: compacting
        if s.isThinking        { return .cWarning }        // orange: working
        if s.isSpeaking        { return .cAccent }        // blue: speaking (canonical state, not string match)
        return .cSuccess                                   // green: idle/listening
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

    // MARK: - Chat Main View

    private var chatMainView: some View {
        ZStack(alignment: .top) {
            if vm.showDebug {
                DebugView(vm: vm)
            } else {
                chatScrollArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Input bar as safeAreaInset: separate layer so messages scroll behind it
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        bottomInputArea
                    }
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
                Color.clear.glassEffect(.regular, in: .rect).ignoresSafeArea(edges: .top)
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
        // Note: voice-color tint applied once on mainAreaView (not duplicated here)
        return ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 20) {
                            // Load older messages button (mirrors web ▲ Load older messages)
                            if vm.activeSession?.hasOlderMessages == true {
                                Button {
                                    if let sid = vm.activeSessionId { vm.loadOlderMessages(sessionId: sid) }
                                } label: {
                                    Label("Load older messages", systemImage: "chevron.up")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.cTextTer)
                                        .padding(.vertical, 6).padding(.horizontal, 12)
                                        .background(Color.cCard.opacity(0.6), in: Capsule())
                                        .overlay(Capsule().strokeBorder(Color.cBorder.opacity(0.5), lineWidth: 0.5))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 4)
                            }
                            ForEach(messageGroups) { group in
                                messageGroupView(group)
                                    .id(group.id)
                                    .transition(.opacity.animation(.easeIn(duration: 0.55)))
                            }
                            if vm.activeSession?.isThinking == true {
                                thinkingBubble.id("thinking")
                                    .transition(.opacity.animation(.easeOut(duration: 0.18)))
                            }
                            // Bottom anchor
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 64).padding(.bottom, 16)
                    }
                    .defaultScrollAnchor(.bottom)
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

                    // Scroll-to-bottom FAB (mirrors web #scroll-bottom-btn)
                    if !isAtBottom {
                        Button {
                            withAnimation(.spring(response: 0.3)) { proxy.scrollTo("bottom", anchor: .bottom) }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.cText)
                                .frame(width: 32, height: 32)
                                .background {
                                    if #available(iOS 26, *) {
                                        Color.clear.glassEffect(.regular, in: .circle)
                                    } else {
                                        Color.canvas2.opacity(0.90).background(.ultraThinMaterial, in: Circle())
                                    }
                                }
                                .overlay(Circle().strokeBorder(Color.glassBorder, lineWidth: 0.5))
                                .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 2)
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 180)
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottomTrailing)))
                        .animation(.spring(response: 0.25), value: isAtBottom)
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
            if msg.isBareAck { return false }
            if msg.role == "agent" { return vm.showAgentMessages }
            if msg.role == "activity" { return vm.verboseMode }
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

        // Agent (inter-agent) messages: match web .msg.agent-msg — arrow+name header, collapsible body
        if role == "agent" {
            // Parse "[Agent msg from/to Name] content" format
            let agentMsgPattern = /^\[Agent msg (from|to) ([^\]]+)\] (.*)/
            let isExpanded = expandedAgentMsgIds.contains(msg.id)
            if let m = msg.text.firstMatch(of: agentMsgPattern) {
                let direction = String(m.output.1)
                let agentName = String(m.output.2)
                let content   = String(m.output.3)
                let arrow     = direction == "from" ? "←" : "→"
                let agentColor = voiceColor(voiceIdByName(agentName))
                return AnyView(
                    VStack(alignment: .leading, spacing: 0) {
                        // Header: arrow + name — matches web .agent-msg border-left style
                        Text("\(arrow) \(agentName)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(agentColor)
                        // Body: hidden when collapsed, shown on tap
                        if isExpanded {
                            Text(content)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.cTextSec)
                                .padding(.top, 3)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10).padding(.vertical, 4)
                    .overlay(alignment: .leading) {
                        agentColor.opacity(0.6).frame(width: 2)
                    }
                    .padding(.leading, 2)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.15)) {
                            if isExpanded { expandedAgentMsgIds.remove(msg.id) }
                            else          { expandedAgentMsgIds.insert(msg.id) }
                        }
                    }
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = msg.text
                            withAnimation { showCopiedToast = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                withAnimation { showCopiedToast = false }
                            }
                        } label: { Label("Copy", systemImage: "doc.on.doc") }
                    }
                )
            }
            // Fallback for non-matching agent text
            return AnyView(
                Text(msg.text)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.cTextSec.opacity(0.65))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 3)
            )
        }

        // Web-matched grouping: flatten tail corners in group, tail 4px on last
        let single = isFirst && isLast
        let tl: CGFloat = (role == "assistant" && !isFirst)  ? 8 : 16
        let bl: CGFloat = role == "assistant" ? (isLast ? 5 : single ? 16 : 8) : 16
        let tr: CGFloat = (role == "user"      && !isFirst)  ? 8 : 16
        let br: CGFloat = role == "user"      ? (isLast ? 5 : single ? 16 : 8) : 16

        let userBubbleColor = Color(hex: 0x2563EB)
        let bubbleBg: AnyShapeStyle = role == "user"
            ? AnyShapeStyle(userBubbleColor)
            : role == "assistant"
                ? AnyShapeStyle(color.opacity(isPlaying ? 0.22 : 0.20))
                : AnyShapeStyle(Color.clear)

        return AnyView(HStack(alignment: .bottom, spacing: 0) {
            if role == "user"   { Spacer(minLength: 56) }
            if role == "system" { Spacer() }

            VStack(alignment: role == "user" ? .trailing : .leading, spacing: 3) {
                // Bubble
                Group {
                    if role == "assistant" {
                        MarkdownContentView(text: msg.text, foreground: Color.cText, fontSize: CGFloat(vm.chatFontSize))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if role == "user" {
                        Text(msg.text)
                            .font(.system(size: CGFloat(vm.chatFontSize)))
                            .lineSpacing(4)
                            .tracking(CGFloat(vm.chatFontSize) * -0.01)
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    } else {
                        Text(msg.text)
                            .font(.caption)
                            .foregroundStyle(Color.cTextTer)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(.horizontal, role == "system" ? 0 : 15)
                .padding(.vertical, role == "system" ? 4 : 10)
                .background(bubbleBg,
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: tl, bottomLeadingRadius: bl,
                        bottomTrailingRadius: br, topTrailingRadius: tr,
                        style: .continuous))
                // Voice tint moved to chatScrollArea background (matches web #main-content tint)
                .overlay {
                    if role == "assistant" {
                        UnevenRoundedRectangle(
                            topLeadingRadius: tl, bottomLeadingRadius: bl,
                            bottomTrailingRadius: br, topTrailingRadius: tr,
                            style: .continuous)
                        .strokeBorder(
                            isPlaying ? color.opacity(isPulsing ? 0.7 : 0.2) : Color(hex: 0x2A3A52),
                            lineWidth: 1)
                        .animation(
                            isPlaying ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true) : .default,
                            value: isPulsing)
                    }
                }
                .shadow(color: role == "assistant" ? Color.black.opacity(0.3) : Color.clear, radius: 3, x: 0, y: 1)
                .contextMenu {
                    if role == "assistant" {
                        Button {
                            vm.playMessageTTS(
                                messageId: msg.id,
                                text: msg.text,
                                voice: vm.activeSession?.voice)
                        } label: {
                            Label(isPlaying ? "Stop Playing" : "Play",
                                  systemImage: isPlaying ? "stop.fill" : "play.fill")
                        }
                        // 👍 user_ack — mirrors web context menu thumbs-up (non-user messages with ID)
                        if let mid = msg.msgId {
                            Button {
                                vm.sendUserAck(msgId: mid)
                                withAnimation { showCopiedToast = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    withAnimation { showCopiedToast = false }
                                }
                            } label: {
                                Label("Acknowledge", systemImage: "hand.thumbsup")
                            }
                        }
                    }
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

                // Timestamp below bubble — shown only on last message in group (mirrors web .msg-ts)
                if role != "system" && isLast {
                    Text(shortTime(msg.timestamp))
                        .font(.system(size: 9))
                        .foregroundStyle(Color.cTextTer)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, alignment: role == "user" ? .trailing : .leading)
                }
            }

            if role == "assistant" { Spacer(minLength: 56) }
            if role == "system"   { Spacer() }
        })
    }

    private static let _fmtToday: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm a"; return f }()
    private static let _fmtOther: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"; return f }()
    private func shortTime(_ date: Date) -> String {
        (Calendar.current.isDateInToday(date) ? Self._fmtToday : Self._fmtOther).string(from: date)
    }

    // MARK: - Thinking Bubble

    private var thinkingBubble: some View {
        let session  = vm.activeSession
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
                    // typing-main-row: gap 5px (matches web)
                    HStack(spacing: 5) {
                        // typingBounce dots — matches web CSS:
                        // 0%,60%,100% { translateY(0), opacity 0.45 }  30% { translateY(-5px), opacity 1 }
                        // period 1.3s, stagger 0.18s per dot, ease-in-out
                        TimelineView(.animation) { tl in
                            HStack(spacing: 5) {
                                ForEach(0..<3, id: \.self) { i in
                                    let t = tl.date.timeIntervalSinceReferenceDate
                                    let period = 1.3
                                    let phase = (t + Double(i) * 0.18).truncatingRemainder(dividingBy: period) / period
                                    let (yOff, opacity): (Double, Double) = {
                                        if phase < 0.3 {
                                            let p = phase / 0.3
                                            let e = p * p * (3 - 2 * p) // smoothstep ≈ ease-in-out
                                            return (-5.0 * e, 0.45 + 0.55 * e)
                                        } else if phase < 0.6 {
                                            let p = (phase - 0.3) / 0.3
                                            let e = p * p * (3 - 2 * p)
                                            return (-5.0 * (1 - e), 1.0 - 0.55 * e)
                                        } else {
                                            return (0, 0.45)
                                        }
                                    }()
                                    Circle()
                                        .fill(Color.cTextTer.opacity(opacity)) // text-tertiary, not voice color
                                        .frame(width: 7, height: 7)
                                        .offset(y: yOff)
                                }
                            }
                        }
                        if hasDetail, let s = session {
                            let summary = s.activity.isEmpty ? s.toolName : s.activity
                            Text(summary)
                                .font(.system(size: 11, weight: .medium)) // 0.78em ≈ 11pt
                                .foregroundStyle(Color.cTextTer)
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

                // Expanded detail (typing-log-expanded)
                if thinkingExpanded, let s = session, hasDetail {
                    VStack(alignment: .leading, spacing: 3) {
                        if !s.activity.isEmpty {
                            Text(s.activity)
                                .font(.system(size: 11, weight: .medium)) // .current line
                                .foregroundStyle(Color.cTextSec)
                                .lineLimit(2).truncationMode(.tail)
                        }
                        if !s.toolName.isEmpty {
                            Text(s.toolName)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.cTextTer)
                                .lineLimit(2).truncationMode(.middle)
                        }
                    }
                    .padding(.top, 7)
                    .overlay(alignment: .top) {
                        Divider().foregroundStyle(Color.cBorder)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10) // matches web padding: 10px 14px
            .background(Color.cCard,                          // matches web var(--bg-card)
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 18, bottomLeadingRadius: 4,
                    bottomTrailingRadius: 18, topTrailingRadius: 18,
                    style: .continuous))
            // No voice color tint overlay — web typing indicator has no tint
            // No border — web .msg-typing-indicator has no border
            .onAppear  { isPulsing = true }
            .onDisappear { isPulsing = false }

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
                    .disabled(vm.isProcessing || vm.recordBlockedByThinking || (vm.micMuted && !vm.isPlaying && !vm.isRecording))
                    .opacity(vm.isProcessing || vm.recordBlockedByThinking || (vm.micMuted && !vm.isPlaying) ? 0.45 : 1)

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
            .padding(.horizontal, 12).padding(.vertical, 8).padding(.bottom, 10)
            .background {
                // RoundedRectangle extends below the screen edge via ignoresSafeArea —
                // bottom corners are hidden behind the screen, pill appears to flow off naturally
                if #available(iOS 26, *) {
                    Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 36, style: .continuous))
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    RoundedRectangle(cornerRadius: 36, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
        }
        .padding(.horizontal, 8).padding(.top, 4)
        // Fill home indicator zone with canvas1 + voice tint, matching mainAreaView
        .background {
            ZStack {
                Color.canvas1
                voiceTintColor.opacity(0.10)
            }.ignoresSafeArea(edges: .bottom)
        }
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
        .frame(height: 12).frame(maxWidth: .infinity)
        .padding(.horizontal, 20).padding(.vertical, 4)
    }

    // MARK: - Mic Button

    private var micButtonVisual: some View {
        ZStack {
            // Pulsing glow ring during tap-to-record
            if vm.isRecording && !vm.pushToTalk {
                Circle()
                    .fill(micColor.opacity(0.18)).frame(width: 104, height: 104)
                    .scaleEffect(isPulsing ? 1.12 : 1.0)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isPulsing)
                Circle()
                    .strokeBorder(micColor.opacity(isPulsing ? 0.5 : 0.1), lineWidth: 1.5)
                    .frame(width: 104, height: 104)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isPulsing)
            }
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
    var fontSize: CGFloat = 15

    /// Parses inline markdown (bold, italic, `code`) using AttributedString so
    /// backtick code spans render as monospaced — LocalizedStringKey does not handle `code`.
    private static func inlineMarkdown(_ str: String) -> AttributedString {
        (try? AttributedString(markdown: str,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(str)
    }

    private enum Block {
        case text(String)
        case header(Int, String)
        case bullet(String)
        case numbered(String, String)
        case code(String, String)   // (language, content)
        case blockquote(String)
        case rule
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
            if line.hasPrefix("> ") { result.append(.blockquote(String(line.dropFirst(2)))); i += 1; continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "***" || trimmed == "___" { result.append(.rule); i += 1; continue }
            let stripped = line.drop(while: { $0 == " " || $0 == "\t" })
            if stripped.hasPrefix("- ") || stripped.hasPrefix("* ") || stripped.hasPrefix("+ ") {
                result.append(.bullet(String(stripped.dropFirst(2)))); i += 1; continue
            }
            if let m = stripped.firstMatch(of: /^(\d+)\. (.+)/) {
                result.append(.numbered(String(m.output.1), String(m.output.2))); i += 1; continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if case .spacing? = result.last {} else { result.append(.spacing) }
                i += 1; continue
            }
            // Merge consecutive plain text lines into one paragraph (matches web paragraph flow)
            if case .text(let prev) = result.last {
                result[result.count - 1] = .text(prev + "\n" + line)
            } else {
                result.append(.text(line))
            }
            i += 1
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
            Text(Self.inlineMarkdown(str))
                .font(.system(size: fontSize))
                .foregroundStyle(foreground)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

        case .header(let level, let str):
            let sz: CGFloat = level == 1 ? fontSize + 4 : level == 2 ? fontSize + 1 : fontSize - 1
            let wt: Font.Weight = level <= 2 ? .bold : .semibold
            Text(Self.inlineMarkdown(str))
                .font(.system(size: sz, weight: wt))
                .foregroundStyle(foreground)
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let str):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(.system(size: fontSize))
                    .foregroundStyle(Color.cTextSec)
                    .frame(width: 10)
                Text(Self.inlineMarkdown(str))
                    .font(.system(size: fontSize))
                    .foregroundStyle(foreground)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .numbered(let num, let str):
            HStack(alignment: .top, spacing: 6) {
                Text("\(num).")
                    .font(.system(size: fontSize))
                    .foregroundStyle(Color.cTextSec)
                    .frame(width: 22, alignment: .trailing)
                Text(Self.inlineMarkdown(str))
                    .font(.system(size: fontSize))
                    .foregroundStyle(foreground)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .blockquote(let str):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Color.cTextTer.opacity(0.5)).frame(width: 3)
                Text(Self.inlineMarkdown(str))
                    .font(.system(size: fontSize))
                    .foregroundStyle(foreground.opacity(0.75))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 2)

        case .rule:
            Divider().background(Color.cBorder)

        case .code(let lang, let content):
            VStack(alignment: .leading, spacing: 0) {
                // Header: language label + copy button (mirrors web .code-copy-btn)
                HStack {
                    Text(lang.isEmpty ? "code" : lang)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.cTextTer)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = content
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.cTextTer)
                            .padding(4)
                    }
                }
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(content)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.cText)
                        .padding(.horizontal, 10)
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

// MARK: - Notes Placeholder (full implementation via Nova)

// Stub — Nova replaces this with full /api/notes implementation
struct NotesPanelView: View {
    let baseURL: URL?
    let onDismiss: () -> Void

    @State private var nowText: String = ""
    @State private var laterText: String = ""
    @State private var activeTab: String = "now"
    @State private var saveStatus: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab picker — matches web notes-tabs
                Picker("Tab", selection: $activeTab) {
                    Text("Now").tag("now")
                    Text("Later").tag("later")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

                // Editor
                if activeTab == "now" {
                    TextEditor(text: $nowText)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.cText)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .padding(.horizontal, 12)
                        .onChange(of: nowText) { _, _ in scheduleSave() }
                } else {
                    TextEditor(text: $laterText)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.cText)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .padding(.horizontal, 12)
                        .onChange(of: laterText) { _, _ in scheduleSave() }
                }

                // Save indicator — matches web .notes-save-indicator
                if !saveStatus.isEmpty {
                    Text(saveStatus)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.cTextTer)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.bottom, 6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.canvas1.ignoresSafeArea())
            .preferredColorScheme(.dark)
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { onDismiss() } } }
            .onAppear { loadNotes() }
            .onDisappear { saveNotes() }
        }
    }

    private func scheduleSave() {
        saveStatus = "Saving…"
        // Debounce — matches web 800ms save timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { saveNotes() }
    }

    private func loadNotes() {
        guard let url = baseURL?.appendingPathComponent("api/notes") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            DispatchQueue.main.async {
                nowText   = json["now"]   as? String ?? ""
                laterText = json["later"] as? String ?? ""
                saveStatus = ""
            }
        }.resume()
    }

    private func saveNotes() {
        guard let url = baseURL?.appendingPathComponent("api/notes") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["now": nowText, "later": laterText])
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            DispatchQueue.main.async {
                let ok = (resp as? HTTPURLResponse)?.statusCode == 200
                saveStatus = ok ? "Saved" : "Save failed"
                if ok { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveStatus = "" } }
            }
        }.resume()
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

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var vm: ClawMuxViewModel
    @Environment(\.dismiss) var dismiss
    @State private var draftURL: String = ""
    @State private var draftTTSURL: String = ""
    @State private var draftSTTURL: String = ""

    var urlChanged: Bool { draftURL.trimmingCharacters(in: .whitespaces) != vm.serverURL.trimmingCharacters(in: .whitespaces) }
    var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—" }
    var appBuild:   String { Bundle.main.infoDictionary?["CFBundleVersion"]            as? String ?? "—" }

    var body: some View {
        NavigationStack {
            Form {
                // Server (iOS-only — not in web settings)
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

                // Text-to-Speech
                Section("Text-to-Speech") {
                    Toggle("Enabled", isOn: $vm.ttsEnabled)
                    if vm.ttsEnabled {
                        TextField("TTS URL", text: $draftTTSURL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .onSubmit { vm.ttsURL = draftTTSURL.trimmingCharacters(in: .whitespaces) }
                        Picker("Playback Speed", selection: Binding(get: { vm.activeSpeed }, set: { vm.activeSpeed = $0 })) {
                            ForEach(SPEED_OPTIONS, id: \.value) { Text($0.label).tag($0.value) }
                        }
                        Toggle("Auto Interrupt", isOn: $vm.autoInterrupt)
                            .onChange(of: vm.autoInterrupt) { _, v in vm.updateSetting("auto_interrupt", value: v) }
                    }
                }

                // Speech-to-Text
                Section("Speech-to-Text") {
                    Toggle("Enabled", isOn: $vm.sttEnabled)
                    if vm.sttEnabled {
                        TextField("STT URL", text: $draftSTTURL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .onSubmit { vm.sttURL = draftSTTURL.trimmingCharacters(in: .whitespaces) }
                        Picker("Whisper Model", selection: $vm.whisperModel) {
                            Text("High (large-v3)").tag("high")
                            Text("Medium").tag("medium")
                            Text("Low (base)").tag("low")
                        }
                        Toggle("Auto Record", isOn: $vm.autoRecord)
                            .onChange(of: vm.autoRecord) { _, v in vm.updateSetting("auto_record", value: v) }
                        Toggle("Auto End", isOn: $vm.vadEnabled)
                            .onChange(of: vm.vadEnabled) { _, v in vm.updateSetting("auto_end", value: v) }
                    }
                }

                // Agent
                Section("Agent") {
                    Picker("Default Model", selection: $vm.defaultModel) {
                        Text("Opus").tag("opus")
                        Text("Sonnet").tag("sonnet")
                        Text("Haiku").tag("haiku")
                    }
                    Picker("Default Effort", selection: $vm.defaultEffort) {
                        Text("High").tag("high")
                        Text("Medium").tag("medium")
                        Text("Low").tag("low")
                    }
                    Toggle("Silent Startup", isOn: $vm.silentStartup)
                    Toggle("Show Agent Messages", isOn: $vm.showAgentMessages)
                    Toggle("Verbose Activity Log", isOn: $vm.verboseMode)
                        .onChange(of: vm.verboseMode) { _, v in vm.updateSetting("activity_verbose", value: v) }
                    if vm.activeSession != nil {
                        Toggle("Walking Mode", isOn: Binding(
                            get: { vm.activeSession?.walkingMode ?? false },
                            set: { _ in vm.toggleWalkingMode() }
                        ))
                    }
                }

                // Sounds
                Section("Sounds") {
                    Toggle("Thinking Sounds", isOn: $vm.soundThinkingAuto)
                        .onChange(of: vm.soundThinkingAuto) { _, v in vm.updateSetting("thinking_sounds", value: v) }
                    Toggle("Audio Cues", isOn: $vm.soundListeningAuto)
                        .onChange(of: vm.soundListeningAuto) { _, v in vm.updateSetting("audio_cues", value: v) }
                }

                // Chat
                Section("Chat") {
                    HStack {
                        Text("Text Size")
                        Spacer()
                        Button { if vm.chatFontSize > 10 { vm.chatFontSize -= 1 } } label: {
                            Image(systemName: "minus").frame(width: 28, height: 28)
                        }.buttonStyle(.bordered)
                        Text("\(vm.chatFontSize)").font(.subheadline).frame(minWidth: 32, alignment: .center)
                        Button { if vm.chatFontSize < 24 { vm.chatFontSize += 1 } } label: {
                            Image(systemName: "plus").frame(width: 28, height: 28)
                        }.buttonStyle(.bordered)
                    }
                }

                // Background Mode (iOS-only)
                Section {
                    Toggle("Background Mode", isOn: $vm.backgroundMode)
                } header: { Text("Background") } footer: {
                    Text(vm.backgroundMode
                         ? "Voice sessions stay alive when the app is backgrounded using a silent audio loop."
                         : "The WebSocket connection may drop when the app is backgrounded.")
                }

                // Live Activity (iOS-only)
                Section {
                    Toggle("Live Activity", isOn: $vm.liveActivityEnabled)
                    if vm.liveActivityEnabled {
                        Toggle("Auto Mode", isOn: $vm.liveActivityAuto)
                        Toggle("Push to Talk", isOn: $vm.liveActivityPTT)
                    }
                } header: { Text("Live Activity") } footer: {
                    Text(vm.liveActivityEnabled
                         ? "Show session status on Dynamic Island and Lock Screen."
                         : "Live Activity is disabled.")
                }

                // Usage
                Section("Usage") {
                    if let pct = vm.usage5hPct {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("5-hour window")
                                if let r = vm.usage5hReset { Text("resets in \(r)").font(.caption2).foregroundStyle(.tertiary) }
                            }
                            Spacer()
                            Text("\(pct)%").font(.subheadline.bold())
                                .foregroundStyle(pct >= 80 ? Color(.systemRed) : pct >= 60 ? Color(.systemOrange) : Color(.systemGreen))
                        }
                    }
                    if let pct = vm.usage7dPct {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("7-day window")
                                if let r = vm.usage7dReset { Text("resets in \(r)").font(.caption2).foregroundStyle(.tertiary) }
                            }
                            Spacer()
                            Text("\(pct)%").font(.subheadline.bold())
                                .foregroundStyle(pct >= 80 ? Color(.systemRed) : pct >= 60 ? Color(.systemOrange) : Color(.systemGreen))
                        }
                    }
                    if vm.usage5hPct == nil && vm.usage7dPct == nil {
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                    Button { UIImpactFeedbackGenerator(style: .light).impactOccurred(); vm.fetchUsage() } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .onAppear { vm.fetchUsage() }

                // Debug
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
            .onAppear {
                draftURL    = vm.serverURL
                draftTTSURL = vm.ttsURL
                draftSTTURL = vm.sttURL
            }
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
