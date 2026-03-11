import SwiftUI

// MARK: - Sidebar Strip View
// Extracted from ContentView. Receives shared @State from ContentView as @Binding.

struct SidebarView: View {
    @ObservedObject var vm: ClawMuxViewModel
    @Binding var sidebarExpanded: Bool
    @Binding var isPulsing: Bool
    @Binding var collapsedProjects: Set<String>
    @Binding var showResetConfirm: Bool
    @Binding var resetVoiceId: String?
    @Binding var showCreateGroupChat: Bool
    @Binding var newGroupChatName: String
    @Namespace private var sidebarNS

    var body: some View {
        sidebarStripView
    }

    // MARK: - Sidebar Strip

    private var sidebarStripView: some View {
        ScrollViewReader { sidebarProxy in
        ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: sidebarExpanded ? 2 : 1) {
                    Color.clear.frame(height: 60).id("sidebar-top")
                    if sidebarExpanded {
                        VStack(spacing: 0) {
                            let groups = projectGroups
                            ForEach(groups.namedProjects, id: \.self) { project in
                                let voices = groups.byProject[project] ?? []
                                projectSection(project, voices: voices)
                            }
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
                        }
                        .transition(.opacity)
                    } else {
                        VStack(spacing: 0) {
                            let groups = projectGroups
                            ForEach(groups.namedProjects, id: \.self) { project in
                                let voices = groups.byProject[project] ?? []
                                let collapsed = collapsedProjects.contains(project)
                                Button {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                        if collapsed { collapsedProjects.remove(project) }
                                        else         { collapsedProjects.insert(project) }
                                    }
                                } label: {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 6, weight: .bold))
                                        .foregroundStyle(Color.cTextSec)
                                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                                        .animation(.spring(response: 0.3), value: collapsed)
                                        .frame(width: 48, height: 14)
                                }
                                if !collapsed {
                                    ForEach(voices) { voice in
                                        sidebarIcon(for: voice)
                                    }
                                }
                            }
                            let chatGroups = activeGroups
                            ForEach(chatGroups, id: \.groupId) { g in
                                groupIcon(g.groupId, voices: g.voices)
                            }
                        }
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .accessibilityIdentifier("SidebarScrollView")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Color.cBorder.opacity(0.5).frame(height: 0.5)
                HStack(spacing: 0) {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            sidebarExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.cTextSec)
                            .frame(width: 48, height: 52)
                    }
                    .accessibilityIdentifier("HamburgerButton")
                    .overlay(alignment: .trailing) {
                        Color.cBorder.frame(width: 0.5)
                    }
                    if sidebarExpanded {
                        Button {
                            vm.showNotes = true
                            withAnimation(.spring(response: 0.3)) { sidebarExpanded = false }
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: "note.text").font(.system(size: 13))
                                Text("Notes").font(.system(size: 10, weight: .medium))
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
                                Text("Settings").font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(Color.cTextSec)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .accessibilityIdentifier("SidebarSettingsButton")
                    }
                }
                .frame(height: 52)
            }
            .background {
                if #available(iOS 26, *) {
                    Color.clear.glassEffect(.regular, in: .rect).ignoresSafeArea(edges: .bottom)
                } else {
                    Color.canvas1.opacity(0.96).ignoresSafeArea(edges: .bottom)
                }
            }
        }
        .frame(width: sidebarExpanded ? 220 : 48)
        .clipped()
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
        .animation(.spring(response: 0.22, dampingFraction: 0.9), value: sidebarExpanded)
        } // ScrollViewReader
    }

    // MARK: - Sidebar Icon (collapsed)

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
                if isSelected { Color.cAccent.opacity(0.08) }
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
                    if inGroup {
                        Text("⬡")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color(hex: 0x0A84FF))
                            .offset(x: 9, y: 9)
                    }
                }
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
            }
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
            Button(role: .destructive) { resetVoiceId = voice.id; showResetConfirm = true } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            if let s = session, !s.groupId.isEmpty {
                Button(role: .destructive) { vm.disbandGroup(s.groupId) } label: {
                    Label("Disband Group Chat", systemImage: "person.2.slash")
                }
            }
            if let s = session {
                Button(role: .destructive) { vm.terminateSession(s.id) } label: {
                    Label("Terminate Session", systemImage: "xmark.circle")
                }
            }
        }
    }

    // MARK: - Project Grouping

    private struct ProjectGroups {
        let namedProjects: [String]
        let byProject:     [String: [VoiceInfo]]
        let ungrouped:     [VoiceInfo]
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
        return ProjectGroups(namedProjects: namedProjects, byProject: byProject, ungrouped: [])
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

    // MARK: - Group Chat Card

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
                    groupCluster(Array(voices.prefix(5)))
                        .frame(width: 34, height: 34)

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

    // MARK: - Group member mini circle (14pt)
    @ViewBuilder
    private func miniCircle(_ v: VoiceInfo) -> some View {
        ZStack {
            Circle().fill(voiceColor(v.id))
            Image(systemName: voiceIcon(v.id))
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(width: 14, height: 14)
        .overlay(Circle().strokeBorder(Color.canvas2, lineWidth: 1))
    }

    // MARK: - Group member cluster (32×32pt, up to 4 icons)
    @ViewBuilder
    private func groupCluster(_ voices: [VoiceInfo]) -> some View {
        let n = voices.count
        ZStack {
            switch n {
            case 0:
                EmptyView()
            case 1:
                miniCircle(voices[0]).position(x: 16, y: 16)
            case 2:
                miniCircle(voices[0]).position(x: 7, y: 16)
                miniCircle(voices[1]).position(x: 25, y: 16)
            case 3:
                miniCircle(voices[0]).position(x: 7, y: 9)
                miniCircle(voices[1]).position(x: 25, y: 9)
                miniCircle(voices[2]).position(x: 16, y: 25)
            default:
                miniCircle(voices[0]).position(x: 7, y: 7)
                miniCircle(voices[1]).position(x: 25, y: 7)
                miniCircle(voices[2]).position(x: 7, y: 25)
                if n == 4 {
                    miniCircle(voices[3]).position(x: 25, y: 25)
                } else {
                    ZStack {
                        Circle().fill(Color.cCard)
                        Text("+\(n - 3)")
                            .font(.system(size: 6, weight: .bold))
                            .foregroundStyle(Color.cTextSec)
                    }
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(Color.canvas2, lineWidth: 1))
                    .position(x: 25, y: 25)
                }
            }
        }
        .frame(width: 32, height: 32)
    }

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
            groupCluster(voices)
                .frame(width: 48, height: 44)
                .background(blue.opacity(0.07))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("GroupChatIcon-\(groupId)")
    }

    // MARK: - Agent Card (expanded sidebar)

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

    // MARK: - Ring Color / Card Status

    func ringColor(_ session: VoiceSession?, spawning: Bool) -> Color {
        if spawning { return .cCaution }
        guard let s = session else { return .cTextTer }
        if s.state == .starting { return .cCaution }
        if s.unreadCount > 0   { return .cDanger }
        if s.state == .compacting { return .cCaution }
        if s.isThinking        { return .cWarning }
        if s.isSpeaking        { return .cAccent }
        return .cSuccess
    }

    func cardStatus(_ session: VoiceSession?, spawning: Bool) -> String {
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
