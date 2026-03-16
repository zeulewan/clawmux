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
        .background(Color.canvas1.ignoresSafeArea(.all))
        .onAppear {
            isPulsing = true
            // Set UIWindow background so keyboard tray matches app color.
            // SceneDelegate.willConnectTo fires before SwiftUI creates the window — do it here instead.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                for scene in UIApplication.shared.connectedScenes {
                    guard let ws = scene as? UIWindowScene else { continue }
                    let bg = UIColor { tc in
                        tc.userInterfaceStyle == .dark
                            ? UIColor(red: 6/255, green: 9/255, blue: 15/255, alpha: 1)
                            : UIColor(red: 244/255, green: 246/255, blue: 251/255, alpha: 1)
                    }
                    ws.windows.forEach { $0.backgroundColor = bg }
                }
            }
        }
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
        // Hard containment boundary — no child view can overflow horizontally into the sidebar.
        .clipped()
        // Voice color background tint — uses @State so animation only fires on explicit onChange,
        // not on every ViewModel re-render (fixes random color flicker on iOS 26)
        .background(voiceTintColor.opacity(0.10).ignoresSafeArea())
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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                InputBarView(
                    vm: vm,
                    pttDragOffset: $pttDragOffset,
                    pttDragOffsetY: $pttDragOffsetY,
                    pttGestureCommitted: $pttGestureCommitted,
                    pttTextFieldFocused: $pttTextFieldFocused,
                    showFilePicker: $showFilePicker,
                    forceTypingMode: true
                )
            }
    }

    private var groupChatHeader: some View {
        GroupChatHeaderView(vm: vm)
    }

    // MARK: - Chat Main View

    private var chatMainView: some View {
        ZStack(alignment: .top) {
            // ChatScrollArea always alive — never destroyed by debug panel toggle
            chatScrollArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: .bottom)
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomInputArea }

            if vm.showDebug {
                DebugView(vm: vm)
                    .transition(.opacity)
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
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Model label — tappable picker for Claude Code, plain label for other backends
                let isClaudeCode = s.backend.isEmpty || s.backend == "claude-code"
                let displayModel = modelName(s.model, modelId: s.modelId)
                if isClaudeCode {
                    Button { showModelPicker = true } label: {
                        Text(displayModel)
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
                } else {
                    Text(displayModel)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.cTextSec)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.glass, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.glassBorder, lineWidth: 0.5))
                        .fixedSize()
                }

                // Effort label — Claude Code only; hidden for other backends
                if isClaudeCode && s.model != "haiku" {
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

                // Mode toggle — hidden when STT is off (text-only mode forced)
                if vm.sttEnabled {
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
            }

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

    private func modelName(_ m: String, modelId: String = "") -> String {
        if !modelId.isEmpty { return modelId }
        switch m { case "sonnet": return "Sonnet"; case "haiku": return "Haiku"; default: return "Opus" }
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
        InputBarView(
            vm: vm,
            pttDragOffset: $pttDragOffset,
            pttDragOffsetY: $pttDragOffsetY,
            pttGestureCommitted: $pttGestureCommitted,
            pttTextFieldFocused: $pttTextFieldFocused,
            showFilePicker: $showFilePicker
        )
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
                debugSection("Status") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(vm.debugStatus.isEmpty ? "Loading…" : vm.debugStatus)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                }
                debugSection("System") {
                    let sys = vm.debugSystem
                    if let cpu = sys.cpuPercent {
                        debugKV("CPU", String(format: "%.0f%%", cpu),
                                color: cpu > 80 ? Theme.red : cpu > 50 ? Theme.yellow : Theme.green)
                    }
                    if sys.ramTotalGB > 0 {
                        debugKV("RAM", String(format: "%.1f / %.1f GB (%.0f%%)", sys.ramUsedGB, sys.ramTotalGB, sys.ramPercent))
                    }
                    if let gpu = sys.gpuPercent {
                        debugKV("GPU", "\(gpu)%",
                                color: gpu > 80 ? Theme.red : gpu > 50 ? Theme.yellow : Theme.green)
                        if sys.vramTotalMB > 0 {
                            debugKV("VRAM", String(format: "%.1f / %.1f GB",
                                                   Double(sys.vramUsedMB) / 1024, Double(sys.vramTotalMB) / 1024))
                        }
                        if let temp = sys.gpuTempC {
                            debugKV("GPU Temp", "\(temp)°C",
                                    color: temp > 80 ? Theme.red : temp > 60 ? Theme.yellow : nil)
                        }
                    }
                }
                debugSection("Hub") {
                    debugKV("Port",    "\(vm.debugHub.port)")
                    debugKV("Uptime",  formatDuration(vm.debugHub.uptimeSeconds))
                    debugKV("Clients", "\(vm.debugHub.clientCount) connected",
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
                                    let proj = [s.project, s.projectRepo].filter { !$0.isEmpty }.joined(separator: " · ")
                                    if !proj.isEmpty {
                                        Text(proj).font(.system(size: 10)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                                    }
                                    Text("idle \(formatDuration(s.idleSeconds))").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                                    Text("age \(formatDuration(s.ageSeconds))").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                                }
                                if !s.workDir.isEmpty {
                                    Text(s.workDir)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(Theme.textTertiary)
                                        .lineLimit(1)
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
                                debugBadge(t.attached ? "attached" : "detached", style: t.attached ? .up : .down)
                                Text(t.created).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                                Spacer()
                            }
                        }
                    }
                }
                debugSection("Actions") {
                    Button {
                        vm.reloadHub()
                    } label: {
                        Text("Reload Hub")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.cCaution)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
        .contentMargins(.leading, 48, for: .scrollContent)
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
    private func debugKV(_ key: String, _ value: String, badge: BadgeStyle? = nil, color: Color? = nil) -> some View {
        HStack(spacing: 8) {
            Text(key).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).frame(width: 80, alignment: .leading)
            if let badge {
                debugBadge(value, style: badge)
            } else {
                Text(value).font(.system(size: 12)).foregroundStyle(color ?? Theme.textPrimary)
            }
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
