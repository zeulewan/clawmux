import Foundation
import UIKit

// MARK: - WebSocket & Hub Protocol

extension ClawMuxViewModel {

    // MARK: - Ping Watchdog

    func startPingWatchdog() {
        lastPingTime = Date()
        pingWatchdogTimer?.invalidate()
        pingWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, self.isConnected, let last = self.lastPingTime else { return }
                if Date().timeIntervalSince(last) > 60 {
                    #if DEBUG
                    print("[ws] No ping for 60s, reconnecting")
                    #endif
                    self.handleDisconnect()
                }
            }
        }
    }

    // MARK: - WebSocket

    /// Public connect — resets backoff (use for user-initiated connects).
    func connect() {
        reconnectAttempt = 0
        connectInternal()
    }

    /// Internal connect — does NOT reset backoff (used by scheduleReconnect).
    func connectInternal() {
        disconnect()
        guard !serverURL.isEmpty else { return }

        var ws = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if ws.hasPrefix("https://") {
            ws = "wss://" + ws.dropFirst(8)
        } else if ws.hasPrefix("http://") {
            ws = "ws://" + ws.dropFirst(7)
        } else if !ws.hasPrefix("ws://") && !ws.hasPrefix("wss://") {
            ws = "wss://" + ws
        }
        if !ws.hasSuffix("/ws") {
            ws += ws.hasSuffix("/") ? "ws" : "/ws"
        }

        guard let url = URL(string: ws) else {
            statusText = "Invalid server URL"
            return
        }

        isConnecting = true
        statusText = "Connecting..."
        urlSession = URLSession(
            configuration: .default, delegate: self, delegateQueue: nil)
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()
    }

    func disconnect() {
        reconnectWork?.cancel()
        reconnectWork = nil
        pingWatchdogTimer?.invalidate()
        pingWatchdogTimer = nil
        usageRefreshTimer?.invalidate()
        usageRefreshTimer = nil
        lastPingTime = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isConnected = false
        isConnecting = false
        stopThinkingSound()
    }

    func scheduleReconnect() {
        reconnectWork?.cancel()
        // Exponential backoff: 2s, 4s, 8s, 16s, capped at 30s
        let delay = min(30.0, 2.0 * pow(2.0, Double(reconnectAttempt)))
        reconnectAttempt += 1
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.connectInternal() }
        }
        reconnectWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func receiveMessage() {
        let task = webSocketTask
        task?.receive { [weak self] result in
            Task { @MainActor in
                // Ignore callbacks from stale tasks (old session cancelled during reconnect)
                guard let self, self.webSocketTask === task else { return }
                switch result {
                case .success(let message):
                    self.handleMessage(message)
                    self.receiveMessage()
                case .failure:
                    self.handleDisconnect()
                }
            }
        }
    }

    func handleDisconnect() {
        guard isConnected || isConnecting else { return }  // debounce duplicate calls
        isConnected = false
        isConnecting = false
        // Do NOT stop recording on disconnect — let it continue locally.
        // When recording ends (VAD/user), stopRecording() stashes audio to pendingAudioSend
        // because !isConnected, and flushPendingAudio() replays it on reconnect.
        if isPlaying || isPlaybackPaused {
            audio.stopPlaybackVAD()
            isPlaying = false
            isPlaybackPaused = false
        }
        isProcessing = false
        audio.currentSuppressNextAutoRecord = false
        clearTranscriptPreview()
        audio.stopPlaybackVAD()
        audio.stopMessageTTS()
        statusText = "Disconnected"
        pingWatchdogTimer?.invalidate()
        pingWatchdogTimer = nil
        lastPingTime = nil
        stopThinkingSound()
        scheduleReconnect()
    }

    func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
            let string = String(data: data, encoding: .utf8)
        else { return }
        let task = webSocketTask
        task?.send(.string(string)) { [weak self] error in
            if let error {
                #if DEBUG
                print("[ws] Send error: \(error)")
                #endif
                Task { @MainActor in
                    guard let self, self.webSocketTask === task else { return }
                    self.handleDisconnect()
                }
            }
        }
    }

    // MARK: - Session Commands

    // sendInterrupt() and flushPendingAudio() live in ClawMuxViewModel+Audio.swift

    func setSessionModel(_ model: String) {
        guard let sid = activeSessionId else { return }
        sendJSON(["session_id": sid, "type": "set_model", "model": model])
        if let idx = sessionIndex(sid) {
            sessions[idx].model = model
        }
    }

    func restartWithModel(_ model: String) {
        guard let sid = activeSessionId else { return }
        sendJSON(["session_id": sid, "type": "restart_model", "model": model])
        if let idx = sessionIndex(sid) {
            sessions[idx].model = model
            sessions[idx].state = .starting
        }
    }

    // Matches web transportPause() — pause/resume in-progress audio without discarding
    func sendUserAck(msgId: String) {
        guard let sid = activeSessionId else { return }
        sendJSON(["session_id": sid, "type": "user_ack", "msg_id": msgId])
    }

    func restartWithEffort(_ effort: String) {
        guard let sid = activeSessionId else { return }
        sendJSON(["session_id": sid, "type": "restart_effort", "effort": effort])
        if let idx = sessionIndex(sid) {
            sessions[idx].effort = effort
            sessions[idx].state = .starting
        }
    }

    func sendEffort(_ effort: String) {
        guard let sid = activeSessionId else { return }
        sendJSON(["session_id": sid, "type": "set_effort", "effort": effort])
        if let idx = sessionIndex(sid) { sessions[idx].effort = effort }
    }

    func sendText() {
        let text = typingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if hapticsSend && typingMode { haptic(.medium) }
        typingText = ""
        if let groupName = activeGroupName {
            sendGroupMessage(text, groupName: groupName)
            return
        }
        guard let sid = activeSessionId else { return }
        let isAwaiting = sessionIndex(sid).flatMap { sessions[$0].awaitingInput } ?? false
        if isAwaiting {
            if let idx = sessionIndex(sid) { sessions[idx].pendingListen = false }
            sendJSON(["session_id": sid, "type": "text", "text": text])
        } else {
            sendJSON(["session_id": sid, "type": "interjection", "text": text])
        }
    }

    // MARK: - Hub Protocol

    func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
            let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else { return }

        let sessionId = json["session_id"] as? String

        switch type {

        // Hub-level messages
        case "session_list":
            if let list = json["sessions"] as? [[String: Any]] {
                let liveIds = Set(list.compactMap { $0["session_id"] as? String })
                // Remove any sessions the hub no longer knows about
                for s in sessions where !liveIds.contains(s.id) {
                    removeSession(s.id)
                }
                // Add new sessions; re-sync state and history for existing ones (reconnect)
                for s in list {
                    if let sid = s["session_id"] as? String {
                        if let idx = sessionIndex(sid) {
                            // Re-sync server-authoritative state (mirrors web session_list reconnect sync)
                            let stateStr = s["state"] as? String ?? ""
                            if let newState = AgentState(rawValue: stateStr) {
                                sessions[idx].state = newState
                            }
                            if let activity = s["activity"] as? String { sessions[idx].activity = activity }
                            if let speed = s["speed"] as? Double { sessions[idx].speed = speed }
                            if let model = s["model"] as? String, !model.isEmpty { sessions[idx].model = model }
                            if let effort = s["effort"] as? String, !effort.isEmpty { sessions[idx].effort = effort }
                            if let backend = s["backend"] as? String { sessions[idx].backend = backend }
                            if let modelId = s["model_id"] as? String { sessions[idx].modelId = modelId }
                            if let project = s["project"] as? String { sessions[idx].project = project }
                            if let area = s["project_area"] as? String { sessions[idx].projectArea = area }
                            if let repo = s["project_repo"] as? String { sessions[idx].projectRepo = repo }
                            if let unread = s["unread_count"] as? Int { sessions[idx].unreadCount = unread }
                            if let gid = s["group_id"] as? String { sessions[idx].groupId = gid }
                            if let wm = s["walking_mode"] as? Bool { sessions[idx].walkingMode = wm }
                            // Cursor-based reconnect sync — appends missed messages (mirrors web _reconnectSyncSession)
                            if let voice = s["voice"] as? String {
                                reconnectSyncHistory(voiceId: voice, sessionId: sid)
                            }
                        } else {
                            addSessionFromDict(s)
                        }
                    }
                }
                // Restore saved active session if it still exists
                if activeSessionId == nil,
                    let savedId = UserDefaults.standard.string(forKey: "activeSessionId"),
                    sessionIndex(savedId) != nil
                {
                    switchToSession(savedId)
                }
            }

        case "session_spawned":
            if let s = json["session"] as? [String: Any],
                let sid = s["session_id"] as? String,
                sessionIndex(sid) == nil
            {
                // Clear spawning state for the voice
                if let voice = s["voice"] as? String {
                    spawningVoiceIds.remove(voice)
                }
                addSessionFromDict(s)
                // Only auto-switch if on the home page
                if activeSessionId == nil && !showDebug && !isFocusMode {
                    switchToSession(sid)
                }
            }

        case "session_terminated":
            if let sid = sessionId {
                removeSession(sid)
            }

        case "project_created", "project_renamed":
            // Re-fetch to get full folder data (name + voices)
            fetchProjects()

        case "project_deleted":
            if let slug = json["slug"] as? String {
                folders.removeAll { $0.id == slug }
            }

        case "project_switched":
            let newProject = json["project"] as? String ?? "default"
            currentProject = newProject
            // Auto-switch to first non-dead session in the new project (mirrors web auto-switch)
            if let match = sessions.first(where: { $0.project == newProject && $0.state != .dead }) {
                switchToSession(match.id)
            } else if activeSessionId != nil {
                // No sessions in new project — deselect (mirrors web switchTab(null))
                activeSessionId = nil
            }

        case "session_status":
            if let sid = sessionId, let idx = sessionIndex(sid) {
                let newState = AgentState(rawValue: json["state"] as? String ?? "") ?? sessions[idx].state
                let prevState = sessions[idx].state
                sessions[idx].state = newState
                sessions[idx].activity = json["activity"] as? String ?? ""
                sessions[idx].toolName = json["tool_name"] as? String ?? ""
                if let b = json["backend"] as? String, !b.isEmpty { sessions[idx].backend = b }
                if let m = json["model_id"] as? String { sessions[idx].modelId = m }

                // First time becoming idle from starting = session just connected
                if prevState == .starting && newState != .starting && newState != .dead {
                    if verboseMode { addMessage(sid, role: "system", text: "Connected.") }
                    if globalSounds, (isAutoMode && soundReadyAuto) || (pushToTalk && soundReadyPTT) {
                        audio.cueSessionReady()
                    }
                    if (isAutoMode && hapticsSessionAuto) || (pushToTalk && hapticsSessionPTT)
                        || (typingMode && hapticsSessionTyping)
                    { haptic(.success) }
                }

                if sid == activeSessionId {
                    // Thinking/processing/compacting show "Ready" in the pill — matches web behavior
                    let pillLabel = newState.isWorking ? "Ready" : newState.displayLabel
                    updateStatusText(pillLabel, for: sid)
                    switch newState {
                    case .thinking, .processing, .compacting:
                        if !typingMode { startThinkingSound() }
                    case .idle, .dead:
                        stopThinkingSound()
                    default:
                        break
                    }
                    updateLiveActivity()
                }
            }

        case "ping":
            lastPingTime = Date()

        case "error":
            let msg = json["message"] as? String ?? "Unknown error"
            if let sid = sessionId {
                updateStatusText("Error: \(msg)", for: sid)
            } else {
                statusText = "Error: \(msg)"
            }

        case "thinking":
            // Legacy event — map to thinking state
            if let sid = sessionId, let idx = sessionIndex(sid) {
                sessions[idx].state = .thinking
                updateStatusText("Ready", for: sid)
                if sid == activeSessionId {
                    if !typingMode { startThinkingSound() }
                    updateLiveActivity()
                }
            }

        // Session-scoped messages
        case "assistant_text":
            if let sid = sessionId, let t = json["text"] as? String {
                let fireAndForget = json["fire_and_forget"] as? Bool ?? false
                if sid == activeSessionId { stopThinkingSound() }
                addMessage(sid, role: "assistant", text: t, ts: json["ts"] as? Double, msgId: json["msg_id"] as? String)
                if sid == activeSessionId {
                    isProcessing = false
                    if fireAndForget {
                        // Fire-and-forget: just show message, no state transition
                    } else {
                        // Converse-driven: transition to listening state (mirrors web setSessionState 'listening')
                        if let idx = sessionIndex(sid) { sessions[idx].state = .idle }
                        if typingMode { updateStatusText("Ready", for: sid) }
                    }
                    updateLiveActivity()
                } else if let idx = sessionIndex(sid) {
                    sessions[idx].unreadCount += 1
                    if !fireAndForget { sessions[idx].state = .idle }
                }
                // Notify in background, gated by per-mode toggle
                if audio.appInBackground {
                    let shouldNotify =
                        (isAutoMode && notifyAuto) || (pushToTalk && notifyPTT)
                        || (typingMode && notifyTyping)
                    if shouldNotify {
                        let voiceName =
                            sessions.first(where: { $0.id == sid })?.label ?? "Agent"
                        sendNotification(title: voiceName, body: t, sessionId: sid)
                    }
                }
            }

        case "user_text":
            if let sid = sessionId, let t = json["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                addMessage(sid, role: "user", text: t, ts: json["ts"] as? Double, msgId: json["msg_id"] as? String)
                if sid == activeSessionId && showTranscriptPreview {
                    clearTranscriptPreview()
                }
                if sid == activeSessionId {
                    isProcessing = false
                    updateLiveActivity()
                }
            }

        case "activity_text":
            if verboseMode, let sid = sessionId, let t = json["text"] as? String {
                addMessage(sid, role: "system", text: "⚙ \(t)", ts: json["ts"] as? Double)
            }

        case "compaction_status":
            if let sid = sessionId, let idx = sessionIndex(sid) {
                let compacting = json["compacting"] as? Bool ?? false
                // When compaction ends, agent is still processing (mirrors web: 'compacting' ? 'compacting' : 'processing')
                sessions[idx].state = compacting ? .compacting : .processing
                if sid == activeSessionId {
                    if !typingMode { startThinkingSound() }
                    updateLiveActivity()
                }
            }

        case "agent_message":
            // Inter-agent message — payload is nested under json["message"]
            // NOTE: agent_message events have NO top-level session_id.
            // Use msg["sender"]/msg["recipient"] (session UUIDs) to route to both sessions,
            // mirroring web: addMessage(msg.recipient, "from X") + addMessage(msg.sender, "to Y")
            if let msg = json["message"] as? [String: Any] {
                let content = msg["content"] as? String ?? ""
                let senderName = msg["sender_name"] as? String ?? "?"
                let recipName = msg["recipient_name"] as? String ?? "?"
                let sName = senderName.prefix(1).uppercased() + senderName.dropFirst()
                let rName = recipName.prefix(1).uppercased() + recipName.dropFirst()
                let isBareAck = (msg["bare_ack"] as? Bool ?? false) || ((msg["parent_id"] != nil) && content.isEmpty)
                if isBareAck { break }
                let senderKey = msg["sender"] as? String ?? ""
                let recipKey = msg["recipient"] as? String ?? ""
                let ts = json["ts"] as? Double
                let msgId = msg["id"] as? String
                #if DEBUG
                print("[agent_msg] sender=\(senderKey) senderName=\(senderName) recip=\(recipKey) recipName=\(recipName) sessions=\(sessions.map { "\($0.id.prefix(8)):\($0.label)" })")
                #endif
                // Find sessions by UUID, falling back to label match (some server paths use name as key)
                let senderSid = sessions.first(where: { $0.id == senderKey || $0.label == senderKey || $0.label.lowercased() == senderName.lowercased() })?.id
                let recipSid  = sessions.first(where: { $0.id == recipKey  || $0.label == recipKey  || $0.label.lowercased() == recipName.lowercased() })?.id
                #if DEBUG
                print("[agent_msg] resolved senderSid=\(senderSid ?? "nil") recipSid=\(recipSid ?? "nil")")
                #endif
                // Add "from X" to recipient's session
                if let sid = recipSid {
                    addMessage(sid, role: "system", text: "[Agent msg from \(sName)] \(content)", ts: ts, msgId: msgId)
                    if sid != activeSessionId, let idx = sessionIndex(sid) {
                        sessions[idx].unreadCount += 1
                    }
                }
                // Add "to Y" to sender's session (skip if same session as recipient)
                if let sid = senderSid, sid != recipSid {
                    addMessage(sid, role: "system", text: "[Agent msg to \(rName)] \(content)", ts: ts, msgId: msgId)
                }
            }

        case "inbox_update":
            // Payload: {"count": N, "latest": {"preview": "..."}}
            if let sid = sessionId, let idx = sessionIndex(sid),
               let count = json["count"] as? Int
            {
                sessions[idx].unreadCount = count
            }

        case "user_ack":
            // Bare thumbs-up ack — store as threading marker (no displayed text)
            if let sid = sessionId, let msgId = json["msg_id"] as? String {
                var ack = ChatMessage(role: "agent", text: "")
                ack.msgId = json["ack_id"] as? String
                ack.parentId = msgId
                ack.isBareAck = true
                if sessionIndex(sid) != nil {
                    messagesBySession[sid, default: []].append(ack)
                }
            }

        case "audio":
            if let sid = sessionId, let b64 = json["data"] as? String,
                let audioData = Data(base64Encoded: b64)
            {
                updateStatusText("Speaking...", for: sid)
                // Always enqueue — drain immediately only if this is the active session
                // and nothing is currently playing. This matches web enqueueAudio logic:
                // never replace a playing player, never drop chunks.
                if sessionIndex(sid) != nil {
                    audioBufferBySession[sid, default: []].append(audioData)
                }
                if sid == activeSessionId {
                    if !isPlaying && !isPlaybackPaused && !isRecording { audio.drainAudioBuffer(sid) }
                    updateLiveActivity()
                }
            }

        case "listening":
            if let sid = sessionId {
                if let idx = sessionIndex(sid) { sessions[idx].state = .idle }
                // Skip if already recording for this session
                if isRecording, audio.currentRecordingSessionId == sid { break }

                // Skip repeated listening if session already has pending listen
                if let idx = sessionIndex(sid), sessions[idx].pendingListen { break }

                // Mic muted: send silent audio immediately
                if micMuted {
                    sendJSON(["session_id": sid, "type": "audio", "data": ""])
                    if let idx = sessionIndex(sid) {
                        sessions[idx].pendingListen = false
                    }
                    updateStatusText("Muted", for: sid)
                    break
                }

                let isActive = sid == activeSessionId
                let isBackground = UIApplication.shared.applicationState != .active

                // Background mode should auto-record even if autoRecord setting is off
                let bgAutoRecord = isBackground && backgroundMode && isAutoMode
                if isActive || (isBackground && (effectiveAutoRecord || bgAutoRecord)) {
                    if audio.currentSuppressNextAutoRecord {
                        // Interrupt was pressed — do NOT set pendingListen.
                        // Setting it here allows recording to leak via switchToSession after
                        // clearSessionSwitchState() clears suppressNextAutoRecord.
                    } else if typingMode {
                        if let idx = sessionIndex(sid) {
                            sessions[idx].pendingListen = true
                        }
                        updateStatusText("Type a message", for: sid)
                    } else if effectiveAutoRecord || bgAutoRecord {
                        // Defer if audio is playing OR buffered — mirrors web pendingListenAfterPlayback
                        let audioActive = isPlaying
                            || !(audioBufferBySession[sid]?.isEmpty ?? true)
                        if audioActive {
                            if let idx = sessionIndex(sid) {
                                sessions[idx].pendingListen = true
                            }
                        } else {
                            if globalSounds && soundListeningAuto { audio.cueListening() }
                            startRecording(sessionId: sid)
                        }
                    } else {
                        if let idx = sessionIndex(sid) {
                            sessions[idx].pendingListen = true
                        }
                        updateStatusText(pushToTalk ? "Hold to Talk" : "Tap Record", for: sid)
                    }
                    updateLiveActivity()
                } else {
                    if let idx = sessionIndex(sid) {
                        sessions[idx].pendingListen = true
                    }
                    updateStatusText("Waiting...", for: sid)
                }
            }

        case "status":
            if let sid = sessionId, let t = json["text"] as? String {
                updateStatusText(t, for: sid)
            }

        case "done":
            if let sid = sessionId, let idx = sessionIndex(sid) {
                // Mirror web: if audio still active (playing or buffered), stay — let
                // playback completion drive the next transition via _checkPendingListen
                let audioStillActive = (isPlaying && audio.currentPlayingSessionId == sid)
                    || !(audioBufferBySession[sid]?.isEmpty ?? true)
                if !audioStillActive {
                    sessions[idx].state = .idle
                    stopThinkingSound()
                    if !sessions[idx].pendingListen {
                        updateStatusText("Ready", for: sid)
                    }
                }
                if sid == activeSessionId {
                    isProcessing = false
                    updateLiveActivity()
                }
            }

        case "session_ended":
            // Agent said goodbye — add message and auto-terminate after 3s (mirrors web)
            if let sid = sessionId {
                addMessage(sid, role: "system", text: "Session ended.")
                if sid == activeSessionId {
                    isProcessing = false
                    stopThinkingSound()
                    updateLiveActivity()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    self?.terminateSession(sid)
                }
            }

        case "project_status":
            if let sid = sessionId, let idx = sessionIndex(sid) {
                sessions[idx].project = json["project"] as? String ?? ""
                sessions[idx].projectArea = json["area"] as? String ?? ""
                sessions[idx].role = json["role"] as? String ?? ""
                sessions[idx].task = json["task"] as? String ?? ""
                sessions[idx].projectRepo = json["project_repo"] as? String ?? ""
            }

        case "groupchat_created", "groupchat_updated":
            // { group: {id, name, voices, members: [{voice, session_id, ...}]} }
            if let g = json["group"] as? [String: Any],
               let gid = g["id"] as? String,
               let name = g["name"] as? String
            {
                let voices = g["voices"] as? [String] ?? []
                // Update knownGroupChats
                groupIdToName[gid] = name
                if let i = knownGroupChats.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
                    knownGroupChats[i] = (name: name, voices: voices)
                } else {
                    knownGroupChats.append((name: name, voices: voices))
                }
                // Sync session groupId from members
                let memberSessionIds = Set((g["members"] as? [[String: Any]] ?? []).compactMap { $0["session_id"] as? String })
                for idx in sessions.indices {
                    if memberSessionIds.contains(sessions[idx].id) {
                        sessions[idx].groupId = gid
                    } else if sessions[idx].groupId == gid {
                        sessions[idx].groupId = ""
                    }
                }
            }

        case "groupchat_deleted":
            // { group_id: "gc-xxx", name: "..." }
            if let gid = json["group_id"] as? String {
                for idx in sessions.indices {
                    if sessions[idx].groupId == gid { sessions[idx].groupId = "" }
                }
                groupIdToName.removeValue(forKey: gid)
            }
            if let name = json["name"] as? String {
                knownGroupChats.removeAll { $0.name.lowercased() == name.lowercased() }
                // Exit deleted group if user is currently viewing it
                if activeGroupName?.lowercased() == name.lowercased() {
                    activeGroupName = nil
                }
            }

        case "groupchat_message":
            // { group_id, group_name, message: {id, role, text, sender, ts} }
            if let msgDict = json["message"] as? [String: Any],
               let msgId = msgDict["id"] as? String,
               let text = msgDict["text"] as? String {
                let senderLabel = msgDict["sender"] as? String ?? ""
                let senderVoice = msgDict["sender_voice"] as? String ?? ""
                let resolvedSender = !senderVoice.isEmpty ? senderVoice :
                    (VOICE_NAME_TO_ID[senderLabel.lowercased()] ?? senderLabel)
                let msg = GroupChatMessage(
                    id: msgId,
                    role: msgDict["role"] as? String ?? "assistant",
                    text: text,
                    sender: resolvedSender,
                    ts: msgDict["ts"] as? Double ?? 0,
                    parentId: msgDict["parent_id"] as? String,
                    isBareAck: msgDict["bare_ack"] as? Bool ?? false
                )
                // Only append if viewing this group and not already present
                let groupName = json["group_name"] as? String ?? ""
                if activeGroupName?.lowercased() == groupName.lowercased(),
                   !groupMessages.contains(where: { $0.id == msgId }) {
                    groupMessages.append(msg)
                }
            }

        default:
            break
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension ClawMuxViewModel: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor in
            guard session === self.urlSession else { return }
            self.isConnected = true
            self.isConnecting = false
            self.reconnectAttempt = 0   // reset backoff on successful connection
            self.statusText = "Connected"
            self.audio.setupAudioSession()
            self.startPingWatchdog()
            self.receiveMessage()
            self.fetchSettings()
            self.fetchUsage()
            self.fetchGroupChats()
            self.fetchProjects()
            self.usageRefreshTimer?.invalidate()
            self.usageRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.fetchUsage()
            }
            self.flushPendingAudio()  // replay audio recorded during disconnect
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor in
            guard session === self.urlSession else { return }
            self.handleDisconnect()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if error != nil {
            Task { @MainActor in
                guard session === self.urlSession else { return }
                self.handleDisconnect()
            }
        }
    }
}
