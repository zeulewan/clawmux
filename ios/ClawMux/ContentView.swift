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
    @State private var sidebarExpanded:        Bool = false

    var body: some View {
        ZStack(alignment: .leading) {
            // Main content — always has 48px left offset for the collapsed sidebar
            mainAreaView
                .padding(.leading, 48)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Dim overlay behind expanded sidebar (z-index 49 matching web)
            if sidebarExpanded {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .padding(.leading, 48)
                    .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { sidebarExpanded = false } }
                    .transition(.opacity)
            }

            // Sidebar (draws over main content when expanded, z-index 50)
            sidebarStripView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas1.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { isPulsing = true }
        .sheet(isPresented: $vm.showSettings) { SettingsView(vm: vm) }
        .sheet(isPresented: $vm.showNotes) { NotesPanelView(serverURL: vm.serverURL) { vm.showNotes = false } }
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

    // MARK: - Split Layout

    private var mainAreaView: some View {
        let voiceTint = vm.activeSession.map { voiceColor($0.voice) } ?? Color.clear
        return Group {
            if vm.activeSessionId != nil {
                chatMainView
            } else {
                welcomeView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Voice color background tint — matches web #main-content backgroundColor = hexToRgba(vc, 0.10)
        // Animates on session switch with 0.4s ease (matches web transition: background-color 0.4s ease)
        .background(voiceTint.opacity(0.10).animation(.easeInOut(duration: 0.4), value: vm.activeSessionId))
    }

    // MARK: - Sidebar (collapsible, 48px → 220px, overlays main when expanded)

    private var sidebarStripView: some View {
        VStack(spacing: 0) {
            // Agent list — icons when collapsed, full cards when expanded
            ScrollView(showsIndicators: false) {
                VStack(spacing: sidebarExpanded ? 2 : 1) {
                    if sidebarExpanded {
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
                                .padding(.top, 8).padding(.bottom, 2)
                            }
                            VStack(spacing: 2) {
                                ForEach(groups.ungrouped) { voice in agentCard(voice) }
                            }
                            .padding(.horizontal, 8)
                        }
                    } else {
                        ForEach(ALL_VOICES) { voice in sidebarIcon(for: voice) }
                    }
                }
                .padding(.vertical, 4)
            }

            Spacer()

            // Bottom tray: hamburger (always) + Notes + Settings (when expanded)
            // Matches web #sidebar-tray: expand-btn(48px) + notes-btn(flex) + settings-btn(flex)
            Color.cBorder.opacity(0.5).frame(height: 0.5)
            HStack(spacing: 0) {
                // Hamburger — always 48px, always visible
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        sidebarExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.cTextSec)
                        .frame(width: 48, height: 52)
                }
                // Notes + Settings — visible only when expanded (clipped otherwise)
                if sidebarExpanded {
                    Button {
                        vm.showNotes = true
                        withAnimation(.spring(response: 0.3)) { sidebarExpanded = false }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "note.text").font(.system(size: 13))
                            Text("Notes").font(.system(size: 8, weight: .medium))
                        }
                        .foregroundStyle(Color.cTextSec)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Button {
                        vm.showSettings = true
                        withAnimation(.spring(response: 0.3)) { sidebarExpanded = false }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "gearshape.fill").font(.system(size: 13))
                            Text("Settings").font(.system(size: 8, weight: .medium))
                        }
                        .foregroundStyle(Color.cTextSec)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(height: 52)
        }
        .frame(width: sidebarExpanded ? 220 : 48)
        .frame(maxHeight: .infinity)
        .background(Color.canvas2)
        .overlay(alignment: .trailing) {
            Color.cBorder.opacity(0.6).frame(width: 0.5)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: sidebarExpanded)
        .clipped()
    }

    private func sidebarIcon(for voice: VoiceInfo) -> some View {
        let session   = vm.sessions.first { $0.voice == voice.id }
        let spawning  = vm.spawningVoiceIds.contains(voice.id)
        let isSelected = vm.activeSession?.voice == voice.id
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
            // Reset — matches web ctx-reset
            Button(role: .destructive) { resetVoiceId = voice.id; showResetConfirm = true } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
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
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ClawMux")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.cText)
                    HStack(spacing: 5) {
                        let dotColor: Color = vm.isConnected ? .cSuccess : vm.isConnecting ? .cCaution : .cDanger
                        Circle().fill(dotColor).frame(width: 7, height: 7)
                        Text(vm.isConnected ? "Live" : vm.isConnecting ? "Connecting..." : "Offline")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.cTextSec)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background {
                if #available(iOS 26, *) { Color.clear.glassEffect(.regular, in: .rect) }
                else { Color.canvas1.opacity(0.95) }
            }

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

    private func agentCard(_ voice: VoiceInfo) -> some View {
        let session    = vm.sessions.first { $0.voice == voice.id }
        let spawning   = vm.spawningVoiceIds.contains(voice.id)
        let isSelected = vm.activeSession?.voice == voice.id
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
            HStack(spacing: 10) {
                // sb-icon: 32px circle with 2px state-color border + glow (hub.html mobile sb-icon)
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
                .frame(width: 32, height: 32)

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
            .padding(.horizontal, 8).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack(alignment: .leading) {
                    // Transparent bg on mobile (hub.html selected overrides to transparent)
                    if isSelected {
                        Color(hex: 0x0A84FF).opacity(0.05)
                    }
                    // Left accent bar: 3px × 28px blue (hub.html mobile .selected::before)
                    if isSelected {
                        Capsule()
                            .fill(Color(hex: 0x0A84FF))
                            .frame(width: 3, height: 28)
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
        guard let s = session else { return Color(hex: 0x48484A) }
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
                VStack(spacing: 0) {
                    chatHeader
                    DebugView(vm: vm)
                }
            } else {
                VStack(spacing: 0) {
                    chatHeader
                    chatScrollArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .bottom) {
                            bottomInputArea
                                .frame(maxWidth: 380)
                        }
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
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.cText)
                    .lineLimit(1)

                // Model label — mirrors web #model-label (clickable)
                Menu {
                    ForEach([("opus","Opus"),("sonnet","Sonnet"),("haiku","Haiku")], id: \.0) { id, name in
                        Button {
                            let cur = vm.activeSession?.model ?? ""
                            if cur != id { pendingModelSwitch = id; showModelRestartConfirm = true }
                        } label: {
                            let cur = vm.activeSession?.model ?? ""
                            HStack {
                                Text(name)
                                if cur == id || (id == "opus" && cur.isEmpty) { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    Text(modelName(s.model))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.cTextSec)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.glass, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.glassBorder, lineWidth: 0.5))
                }

                // Effort label — mirrors web #effort-label (clickable)
                Menu {
                    ForEach(["low","medium","high"], id: \.self) { level in
                        Button { vm.sendEffort(level) } label: {
                            HStack { Text(level.capitalized); if s.effort == level { Image(systemName: "checkmark") } }
                        }
                    }
                } label: {
                    Text(s.effort.isEmpty ? "Med" : String(s.effort.prefix(3)).capitalized)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.cTextTer)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.glass, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.glassBorder, lineWidth: 0.5))
                }

                // Mode toggle — mirrors web #mode-toggle button
                Button { cycleInputMode() } label: {
                    Text(vm.typingMode ? "Text" : "Voice")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.cTextSec)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.glass, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.glassBorder, lineWidth: 0.5))
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
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.glass, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.glassBorder, lineWidth: 0.5))
                }
            }

            // Connection dot pill — mirrors web #dot + #conn-label ("Live" / "Connecting..." / "Offline")
            let dotColor: Color = vm.isConnected ? .cSuccess : vm.isConnecting ? .cCaution : .cDanger
            let connLabel: String = vm.isConnected ? "Live" : vm.isConnecting ? "Connecting..." : "Offline"
            HStack(spacing: 5) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .scaleEffect(vm.isConnecting && isPulsing ? 1.15 : vm.isConnecting ? 0.7 : 1.0)
                    .opacity(vm.isConnecting && isPulsing ? 1.0 : vm.isConnecting ? 0.15 : 1.0)
                    .animation(vm.isConnecting ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: isPulsing)
                Text(connLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.cTextTer)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.glass, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.glassBorder, lineWidth: 0.5))
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
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
                ZStack(alignment: .bottomTrailing) {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 20) {
                            Spacer(minLength: 0).frame(maxHeight: .infinity)
                            ForEach(messageGroups) { group in
                                messageGroupView(group)
                                    .id(group.id)
                                    .transition(.opacity.animation(.easeIn(duration: 0.55)))
                            }
                            if vm.activeSession?.isThinking == true {
                                thinkingBubble.id("thinking")
                            }
                            // Bottom anchor
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 16).padding(.bottom, 170)
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

                    // Scroll-to-bottom FAB (mirrors web #scroll-bottom-btn)
                    if !isAtBottom {
                        Button {
                            withAnimation(.spring(response: 0.3)) { proxy.scrollTo("bottom", anchor: .bottom) }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.cText)
                                .frame(width: 32, height: 32)
                                .background(Color.cCard, in: Circle())
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
            if msg.role == "system" || msg.role == "agent" || msg.role == "activity" { return vm.verboseMode }
            if msg.isBareAck { return false }
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

        // Agent (inter-agent) messages: compact inline style like web's agent-msg
        if role == "agent" {
            return AnyView(
                Text(msg.text)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.cTextSec.opacity(0.65))
                    .lineLimit(3).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 2)
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

        // Web-matched grouping: flatten tail corners in group, tail 4px on last
        let single = isFirst && isLast
        let tl: CGFloat = (role == "assistant" && !isFirst)  ? 8 : 16
        let bl: CGFloat = role == "assistant" ? (isLast ? 4 : single ? 16 : 8) : 16
        let tr: CGFloat = (role == "user"      && !isFirst)  ? 8 : 16
        let br: CGFloat = role == "user"      ? (isLast ? 4 : single ? 16 : 8) : 16

        let userBubbleColor = Color(hex: 0x2563EB)
        let bubbleBg: AnyShapeStyle = role == "user"
            ? AnyShapeStyle(userBubbleColor)
            : role == "assistant"
                ? AnyShapeStyle(isPlaying ? color.opacity(0.22) : Color.cCard)
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
                .padding(.horizontal, 15).padding(.vertical, 10)
                .background(bubbleBg,
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: tl, bottomLeadingRadius: bl,
                        bottomTrailingRadius: br, topTrailingRadius: tr,
                        style: .continuous))
                .overlay(
                    // Voice color tint on assistant bubbles
                    UnevenRoundedRectangle(
                        topLeadingRadius: tl, bottomLeadingRadius: bl,
                        bottomTrailingRadius: br, topTrailingRadius: tr,
                        style: .continuous)
                        .fill(role == "assistant" ? color.opacity(0.12) : Color.clear)
                )
                .overlay {
                    if role == "assistant" {
                        UnevenRoundedRectangle(
                            topLeadingRadius: tl, bottomLeadingRadius: bl,
                            bottomTrailingRadius: br, topTrailingRadius: tr,
                            style: .continuous)
                        .strokeBorder(
                            isPlaying ? color.opacity(isPulsing ? 0.7 : 0.2) : Color(hex: 0x2A3A52),
                            lineWidth: 0.5)
                        .animation(
                            isPlaying ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true) : .default,
                            value: isPulsing)
                    }
                }
                .shadow(color: role == "assistant" ? Color.black.opacity(0.3) : Color.clear, radius: 1.5, x: 0, y: 1)
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
                    } else if !vm.statusText.isEmpty {
                        // Status text in controls-left — matches web #status div
                        let sc = statusColor
                        Text(vm.statusText)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(sc)
                            .lineLimit(1)
                            .transition(.opacity)
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
                        s.isThinking || s.state == .starting
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
            }
            .padding(.horizontal, 12).padding(.vertical, 8).padding(.bottom, 2)
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
        // Mirrors web #text-input-bar: single row [text-stop?] [textarea] [send]
        // Container: padding 8px 12px, border-radius 20px, glass/blur
        HStack(alignment: .bottom, spacing: 8) {
            // Stop button — mirrors web #text-stop (38x38, red, in-flow, shown when agent working)
            if let s = vm.activeSession, s.isThinking || s.state == .starting {
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

            // Text input — mirrors web #text-input (flex:1, transparent, padding 8px 4px)
            TextField("Message", text: $vm.typingText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...5)
                .foregroundStyle(Color.cText)
                .padding(.horizontal, 4).padding(.vertical, 8)
                .onSubmit { vm.sendText() }.submitLabel(.send)

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
                Color.clear
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.glassBorder, lineWidth: 0.5))
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

// MARK: - Notes Placeholder (full implementation via Nova)

// Stub — Nova replaces this with full /api/notes implementation
struct NotesPanelView: View {
    let serverURL: String
    let onDismiss: () -> Void

    @State private var nowText: String = ""
    @State private var laterText: String = ""
    @State private var activeTab: String = "now"
    @State private var saveStatus: String = ""
    private var saveTimer: DispatchWorkItem? = nil

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
        guard let url = URL(string: "\(serverURL)/api/notes") else { return }
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
        guard let url = URL(string: "\(serverURL)/api/notes") else { return }
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
                }

                // Sounds
                Section("Sounds") {
                    Toggle("Thinking Sounds", isOn: $vm.soundThinkingAuto)
                    Toggle("Audio Cues", isOn: $vm.soundListeningAuto)
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
                    Toggle("Auto Mode", isOn: $vm.liveActivityAuto)
                    Toggle("Push to Talk", isOn: $vm.liveActivityPTT)
                } header: { Text("Live Activity") } footer: {
                    Text("Show session status on Dynamic Island and Lock Screen.")
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
