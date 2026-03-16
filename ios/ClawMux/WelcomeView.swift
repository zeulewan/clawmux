import SwiftUI

// MARK: - Welcome View
// Shown when no session is active. Contains agent list with project grouping.

struct WelcomeView: View {
    @ObservedObject var vm: ClawMuxViewModel
    @State private var isPulsing = false
    @Binding var collapsedProjects: Set<String>
    @Binding var sidebarExpanded: Bool
    @Binding var showResetConfirm: Bool
    @Binding var resetVoiceId: String?

    var body: some View {
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
                    let sessionMap = Dictionary(vm.sessions.map { ($0.voice, $0) }, uniquingKeysWith: { a, _ in a })
                    ForEach(groups.namedProjects, id: \.self) { project in
                        projectSection(project, voices: groups.byProject[project] ?? [], sessionMap: sessionMap)
                    }
                }
                .padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.leading, 48)
        .onAppear { isPulsing = true }
    }

    // MARK: - Project Grouping

    private struct ProjectGroups {
        let namedProjects: [String]
        let byProject:     [String: [VoiceInfo]]
    }

    private var projectGroups: ProjectGroups {
        let voiceLookup = Dictionary(uniqueKeysWithValues: ALL_VOICES.map { ($0.id, $0) })
        var byProject: [String: [VoiceInfo]] = [:]
        var assignedIds = Set<String>()
        for folder in vm.folders {
            let voices = folder.voices.compactMap { voiceLookup[$0] }
            if !voices.isEmpty {
                byProject[folder.name] = voices
                voices.forEach { assignedIds.insert($0.id) }
            }
        }
        let other = ALL_VOICES.filter { !assignedIds.contains($0.id) }
        if !other.isEmpty {
            byProject["Other"] = other
        }
        let folderOrder = vm.folders.compactMap { f -> String? in
            byProject[f.name] != nil ? f.name : nil
        }
        let namedProjects = byProject["Other"] != nil ? folderOrder + ["Other"] : folderOrder
        return ProjectGroups(namedProjects: namedProjects, byProject: byProject)
    }

    @ViewBuilder
    private func projectSection(_ project: String, voices: [VoiceInfo], sessionMap: [String: VoiceSession]) -> some View {
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
                    ForEach(voices) { voice in agentCard(voice, sessionMap: sessionMap) }
                }
                .padding(.horizontal, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Agent Card

    private func agentCard(_ voice: VoiceInfo, sessionMap: [String: VoiceSession]) -> some View {
        let session    = sessionMap[voice.id]
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
                        if !s.projectRepo.isEmpty {
                            Text(s.projectRepo)
                                .font(.system(size: 8, weight: .regular))
                                .foregroundStyle(Color(hex: 0x3A86FF).opacity(0.75))
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
                    if isSelected {
                        Color(.systemPurple).opacity(0.08)
                    }
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
            Group {
            if session == nil {
                Button { vm.spawnSession(voiceId: voice.id) } label: {
                    Label("Launch Session", systemImage: "play.circle")
                }
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

    // MARK: - Ring Color / Card Status

    private func ringColor(_ session: VoiceSession?, spawning: Bool) -> Color {
        if spawning { return .cCaution }
        guard let s = session else { return .cTextTer }
        if s.state == .starting { return .cCaution }
        if s.unreadCount > 0   { return .cDanger }
        if s.state == .compacting { return .cCaution }
        if s.isThinking        { return .cWarning }
        if s.isSpeaking        { return .cAccent }
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
}
