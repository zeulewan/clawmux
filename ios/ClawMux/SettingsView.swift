import SwiftUI

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var vm: ClawMuxViewModel
    @Environment(\.dismiss) var dismiss
    @State private var draftURL: String = ""
    @State private var draftTTSURL: String = ""
    @State private var draftSTTURL: String = ""
    @State private var newFolderName: String = ""
    @State private var showNewFolderField: Bool = false
    @State private var renamingFolder: ProjectFolder? = nil
    @State private var renameFolderName: String = ""
    @State private var deletingFolder: ProjectFolder? = nil
    @State private var newGroupName: String = ""
    @State private var showNewGroupField: Bool = false

    var urlChanged: Bool { draftURL.trimmingCharacters(in: .whitespaces) != vm.serverURL.trimmingCharacters(in: .whitespaces) }
    var appVersion:  String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—" }
    var appBuild:    String { Bundle.main.infoDictionary?["CFBundleVersion"]            as? String ?? "—" }
    var appCommit:   String { Bundle.main.infoDictionary?["GIT_COMMIT_HASH"]            as? String ?? "—" }

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
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            vm.activateWalkingMode()
                        }
                    } label: {
                        Label("Walking Mode (Puck)", systemImage: "figure.walk")
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

                // Folders
                Section("Folders") {
                    ForEach(vm.folders) { folder in
                        HStack {
                            Text(folder.name)
                            Spacer()
                            Text("\(folder.voices.count)").font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if folder.id != "default" {
                                Button(role: .destructive) { deletingFolder = folder } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button { renamingFolder = folder; renameFolderName = folder.name } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                    if showNewFolderField {
                        HStack {
                            TextField("Folder name", text: $newFolderName)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("Add") {
                                vm.createFolder(name: newFolderName.trimmingCharacters(in: .whitespaces))
                                newFolderName = ""; showNewFolderField = false
                            }
                            .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
                            Button("Cancel", role: .cancel) { newFolderName = ""; showNewFolderField = false }
                        }
                    } else {
                        Button { showNewFolderField = true } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }
                    }
                }
                .alert("Rename Folder", isPresented: Binding(
                    get: { renamingFolder != nil },
                    set: { if !$0 { renamingFolder = nil } }
                )) {
                    TextField("New name", text: $renameFolderName)
                    Button("Rename") {
                        if let f = renamingFolder {
                            vm.renameFolder(f.id, newName: renameFolderName.trimmingCharacters(in: .whitespaces))
                        }
                        renamingFolder = nil
                    }
                    Button("Cancel", role: .cancel) { renamingFolder = nil }
                } message: { Text("Enter a new name for \"\(renamingFolder?.name ?? "")\"") }
                .alert("Delete Folder", isPresented: Binding(
                    get: { deletingFolder != nil },
                    set: { if !$0 { deletingFolder = nil } }
                )) {
                    Button("Delete", role: .destructive) {
                        if let f = deletingFolder { vm.deleteFolder(f.id) }
                        deletingFolder = nil
                    }
                    Button("Cancel", role: .cancel) { deletingFolder = nil }
                } message: { Text("Delete \"\(deletingFolder?.name ?? "")\"? Agents in this folder will be moved to Default.") }

                // Group Chats
                Section("Group Chats") {
                    ForEach(vm.knownGroupChats, id: \.name) { gc in
                        HStack {
                            Text(gc.name)
                            Spacer()
                            Text("\(gc.voices.count) members").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if showNewGroupField {
                        HStack {
                            TextField("Group name", text: $newGroupName)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("Create") {
                                vm.createGroupChat(name: newGroupName.trimmingCharacters(in: .whitespaces))
                                newGroupName = ""; showNewGroupField = false
                            }
                            .disabled(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
                            Button("Cancel", role: .cancel) { newGroupName = ""; showNewGroupField = false }
                        }
                    } else {
                        Button { showNewGroupField = true } label: {
                            Label("New Group Chat", systemImage: "bubble.left.and.bubble.right")
                        }
                    }
                }

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
                    HStack { Text("Commit");  Spacer(); Text(appCommit).foregroundStyle(.secondary).font(.system(.subheadline, design: .monospaced)) }
                } footer: {
                    VStack(spacing: 2) {
                        Text("ClawMux")
                            .font(.caption2).foregroundStyle(.tertiary)
                        Text("© Zeul Mordasiewicz")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center).padding(.top, 4)
                }
            }
            .scrollContentBackground(.hidden)
            .listRowBackground(Color.clear)
            .background(Color.clear)
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                draftURL    = vm.serverURL
                draftTTSURL = vm.ttsURL
                draftSTTURL = vm.sttURL
            }
            .onDisappear {
                let tts = draftTTSURL.trimmingCharacters(in: .whitespaces)
                let stt = draftSTTURL.trimmingCharacters(in: .whitespaces)
                if tts != vm.ttsURL { vm.ttsURL = tts }
                if stt != vm.sttURL { vm.sttURL = stt }
            }
        }
        .background(Color.clear)
        // iOS 26: system provides liquid glass sheet automatically — no presentationBackground needed
        // iOS <26: apply material fallback
        .modifier(SheetBackgroundModifier())
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
