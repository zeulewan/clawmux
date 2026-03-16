import Foundation
import UIKit

// MARK: - Helpers, History & Session Management

extension ClawMuxViewModel {

    // MARK: - Helpers

    func sessionIndex(_ id: String) -> Int? {
        sessions.firstIndex { $0.id == id }
    }

    /// Update status text for a session, and if it's the active session, also update the top-level statusText.
    func updateStatusText(_ text: String, for sessionId: String) {
        if let idx = sessionIndex(sessionId) {
            sessions[idx].statusText = text
        }
        if sessionId == activeSessionId {
            statusText = text
        }
    }

    func addMessage(_ sessionId: String, role: String, text: String, ts: Double? = nil, msgId: String? = nil) {
        guard sessionIndex(sessionId) != nil else { return }
        // Deduplicate by server message ID
        if let msgId, messagesBySession[sessionId]?.contains(where: { $0.msgId == msgId }) == true { return }
        var msg = ChatMessage(role: role, text: text)
        if let ts { msg.timestamp = Date(timeIntervalSince1970: ts) }
        msg.msgId = msgId
        messagesBySession[sessionId, default: []].append(msg)
    }

    // MARK: - Server-Side History

    func fetchHistory(voiceId: String, sessionId: String, initialState: AgentState? = nil) {
        guard let baseURL = httpBaseURL() else { return }
        // Request last 30 messages from server — server slices correctly using before_ts pagination
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("api/history/\(voiceId)"),
            resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "limit", value: "100")]
        guard let url = comps.url else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let messages = json["messages"] as? [[String: Any]]
            else { return }
            // Extract Sendable values before entering the actor context
            let hasMore = json["has_more"] as? Bool ?? false
            let chatMessages: [ChatMessage] = messages.compactMap { msg in
                guard let role = msg["role"] as? String, let text = msg["text"] as? String else { return nil }
                var m = ChatMessage(role: role, text: text)
                if let ts = msg["ts"] as? Double { m.timestamp = Date(timeIntervalSince1970: ts) }
                if let mid = msg["id"] as? String { m.msgId = mid }
                if let pid = msg["parent_id"] as? String { m.parentId = pid }
                if msg["bare_ack"] as? Bool == true { m.isBareAck = true }
                return m
            }
            Task { @MainActor in
                guard let self, let idx = self.sessionIndex(sessionId) else { return }
                if !chatMessages.isEmpty {
                    self.messagesBySession[sessionId] = chatMessages
                    // Use server's has_more — counts all stored messages, not just visible ones
                    self.sessions[idx].hasOlderMessages = hasMore
                } else if let state = initialState {
                    // No history yet — show appropriate placeholder (mirrors web addSession)
                    let isReady = state != .starting && state != .dead
                    let placeholder = isReady ? "Connected." : "Session started. Connecting..."
                    self.messagesBySession[sessionId] = [ChatMessage(role: "system", text: placeholder)]
                }
            }
        }.resume()
    }

    // Cursor-based reconnect sync — appends only messages after the last known ID.
    // Falls back to full fetchHistory if no cursor is available (empty history).
    // Mirrors web _reconnectSyncSession.
    func reconnectSyncHistory(voiceId: String, sessionId: String) {
        guard sessionIndex(sessionId) != nil else { return }

        // Find last message with a server-assigned ID (cursor)
        let cursor = messagesBySession[sessionId]?.reversed().first(where: { $0.msgId != nil })?.msgId
        let messagesEmpty = messagesBySession[sessionId]?.isEmpty ?? true

        if cursor == nil && messagesEmpty {
            // No history yet — full fetch with placeholder
            fetchHistory(voiceId: voiceId, sessionId: sessionId)
            return
        }
        guard let cursor else { return } // Has messages but no IDs — nothing to sync

        guard let baseURL = httpBaseURL() else { return }
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("api/history/\(voiceId)"),
            resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "project", value: currentProject),
            URLQueryItem(name: "after", value: cursor),
        ]
        guard let url = comps.url else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let messages = json["messages"] as? [[String: Any]]
            else { return }
            Task { @MainActor in
                guard let self, let _ = self.sessionIndex(sessionId) else { return }
                for msg in messages {
                    guard let role = msg["role"] as? String,
                        let text = msg["text"] as? String
                    else { continue }
                    let ts = msg["ts"] as? Double
                    let mid = msg["id"] as? String
                    let parentId = msg["parent_id"] as? String
                    let isBareAck = msg["bare_ack"] as? Bool ?? false
                    // addMessage deduplicates by msgId — safe to call even on overlap
                    var m = ChatMessage(role: role, text: text)
                    if let ts { m.timestamp = Date(timeIntervalSince1970: ts) }
                    m.msgId = mid
                    m.parentId = parentId
                    m.isBareAck = isBareAck
                    if let msgId = mid,
                        self.messagesBySession[sessionId]?.contains(where: { $0.msgId == msgId }) == true
                    { continue } // skip duplicates
                    if self.sessionIndex(sessionId) != nil {
                        self.messagesBySession[sessionId, default: []].append(m)
                    }
                }
            }
        }.resume()
    }

    func resetHistory(voiceId: String) {
        guard let baseURL = httpBaseURL() else { return }
        let url = baseURL.appendingPathComponent("api/history/\(voiceId)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()

        // Terminate session if active (reset clears everything)
        if let session = sessions.first(where: { $0.voice == voiceId }) {
            terminateSession(session.id)
        }
    }

    // Paginate backwards using server-side before_ts cursor (every message has ts).
    // GET /api/history/:voice?limit=30&before_ts=<oldest_ts>
    func loadOlderMessages(sessionId: String, completion: (() -> Void)? = nil) {
        guard let idx = sessionIndex(sessionId),
              let baseURL = httpBaseURL() else { completion?(); return }
        let session = sessions[idx]
        // Use timestamp of the oldest currently-loaded message as cursor
        let oldestTs = messagesBySession[sessionId]?.map(\.timestamp.timeIntervalSince1970).min()
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("api/history/\(session.voice)"),
            resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [URLQueryItem(name: "limit", value: "100")]
        if let ts = oldestTs {
            items.append(URLQueryItem(name: "before_ts", value: String(ts)))
        }
        comps.queryItems = items
        guard let url = comps.url else { completion?(); return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let messages = json["messages"] as? [[String: Any]]
            else { completion?(); return }
            // Extract Sendable values before entering the actor context
            let hasMore = json["has_more"] as? Bool ?? (messages.count >= 100)
            let older: [ChatMessage] = messages.compactMap { msg in
                guard let role = msg["role"] as? String, let text = msg["text"] as? String else { return nil }
                var m = ChatMessage(role: role, text: text)
                if let ts = msg["ts"] as? Double { m.timestamp = Date(timeIntervalSince1970: ts) }
                if let mid = msg["id"] as? String { m.msgId = mid }
                if let pid = msg["parent_id"] as? String { m.parentId = pid }
                if msg["bare_ack"] as? Bool == true { m.isBareAck = true }
                return m
            }
            Task { @MainActor in
                guard let self, let i = self.sessionIndex(sessionId) else { return }
                guard !older.isEmpty else {
                    self.sessions[i].hasOlderMessages = false
                    completion?()
                    return
                }
                // Deduplicate: prefer msgId match, fall back to timestamp
                let existing = self.messagesBySession[sessionId] ?? []
                let existingIds = Set(existing.compactMap { $0.msgId })
                let existingTs  = Set(existing.filter { $0.msgId == nil }.map { $0.timestamp.timeIntervalSince1970 })
                let newOlder = older.filter { m in
                    if let mid = m.msgId { return !existingIds.contains(mid) }
                    return !existingTs.contains(m.timestamp.timeIntervalSince1970)
                }
                self.messagesBySession[sessionId] = newOlder + existing
                // Use server's has_more — accurate count regardless of message types
                self.sessions[i].hasOlderMessages = hasMore
                completion?()
            }
        }.resume()
    }

    // MARK: - Session Management

    func addSessionFromDict(_ dict: [String: Any]) {
        let sid = dict["session_id"] as? String ?? UUID().uuidString
        let voice = dict["voice"] as? String ?? "af_sky"
        let label =
            ALL_VOICES.first { $0.id == voice }?.name ?? dict["label"] as? String ?? "Session"
        let tmux = dict["tmux_session"] as? String ?? sid

        // Canonical state from backend; fall back to legacy status field
        let stateStr = dict["state"] as? String ?? dict["status"] as? String ?? "starting"
        let agentState = AgentState(rawValue: stateStr) ?? .starting

        // Restore saved voice/speed preferences
        let savedPrefs = loadSessionPrefs(sid)
        let sessionVoice = savedPrefs?.voice ?? voice
        let sessionSpeed = savedPrefs?.speed ?? 1.0
        let sessionLabel = ALL_VOICES.first { $0.id == sessionVoice }?.name ?? label

        var session = VoiceSession(
            id: sid, label: sessionLabel, voice: sessionVoice, speed: sessionSpeed,
            state: agentState, tmuxSession: tmux)
        session.project = dict["project"] as? String ?? ""
        session.projectArea = dict["project_area"] as? String ?? ""
        session.role = dict["role"] as? String ?? ""
        session.task = dict["task"] as? String ?? ""
        session.projectRepo = dict["project_repo"] as? String ?? ""
        session.model = dict["model"] as? String ?? ""
        session.effort = dict["effort"] as? String ?? ""
        session.backend = dict["backend"] as? String ?? ""
        session.modelId = dict["model_id"] as? String ?? ""
        session.activity = dict["activity"] as? String ?? ""
        session.toolName = dict["tool_name"] as? String ?? ""
        session.unreadCount = dict["unread_count"] as? Int ?? 0
        session.groupId = dict["group_id"] as? String ?? ""
        session.walkingMode = dict["walking_mode"] as? Bool ?? false

        sessions.append(session)

        // Fetch message history from server; add a placeholder only if history comes back empty
        fetchHistory(voiceId: voice, sessionId: sid, initialState: agentState)
    }

    func switchToFocus() {
        audio.pauseCurrentPlaybackForSessionSwitch()
        if isRecording { stopRecording(discard: true) }
        stopThinkingSound()
        isFocusMode = true
        activeSessionId = nil
        showDebug = false
    }

    func exitFocusMode() {
        isFocusMode = false
    }

    func switchToSession(_ id: String) {
        if activeSessionId != id {
            // Pause audio from previous session (don't stop/interrupt)
            audio.pauseCurrentPlaybackForSessionSwitch()
            if isRecording { stopRecording(discard: true) }
            stopThinkingSound()
            audio.clearSessionSwitchState()
            showPTTTextField = false
            pttPreviewText = ""
            pttTranscriptionError = nil
            clearTranscriptPreview()
            typingText = ""  // clear draft — shared field should not leak between agents
        }
        activeSessionId = id
        activeGroupName = nil
        showDebug = false
        isFocusMode = false

        // Clear unread and tell server we're viewing this session
        if let idx = sessionIndex(id), sessions[idx].unreadCount > 0 {
            sessions[idx].unreadCount = 0
        }
        markSessionViewing(id)
        fetchUsage()  // refresh context % for new active session (matches web switchTab → fetchUsage)

        endLiveActivity()
        if !typingMode {
            startLiveActivity(sessionId: id)
        }

        if let session = activeSession {
            let fallback = session.state.isWorking ? "Ready" : session.state.displayLabel
            statusText = session.statusText.isEmpty ? fallback : session.statusText

            // Derive processing state from session (don't carry over from previous session)
            isProcessing = session.state.isWorking

            // Resume thinking sound if session is busy (not in typing mode)
            if session.isThinking && !typingMode {
                startThinkingSound()
            }

            // Resume paused audio for this session
            if audio.hasPausedAudioForSession == id {
                if !audio.resumePlaybackForSession(id) {
                    // resume failed — nothing to drain
                }
            }
            // Play buffered audio received while in background
            else if !(audioBufferBySession[id]?.isEmpty ?? true) {
                audio.drainAudioBuffer(id)
            }
            // Handle pending listen
            else if session.pendingListen {
                if typingMode {
                    statusText = "Type a message"
                } else {
                    if let idx = sessionIndex(id) {
                        sessions[idx].pendingListen = false
                    }
                    if micMuted {
                        sendJSON(["session_id": id, "type": "audio", "data": ""])
                        statusText = "Muted"
                    } else if effectiveAutoRecord {
                        if globalSounds && soundListeningAuto { audio.cueListening() }
                        startRecording(sessionId: id)
                    } else {
                        statusText = pushToTalk ? "Hold to Talk" : "Tap Record"
                    }
                }
            }

            // Sync mode with hub
            sendJSON(["session_id": id, "type": "set_mode", "mode": typingMode ? "text" : "voice"])
        }
    }

    func spawnSession(voiceId: String = "") {
        guard let baseURL = httpBaseURL() else { return }
        let url = baseURL.appendingPathComponent("api/sessions")

        if !voiceId.isEmpty { spawningVoiceIds.insert(voiceId) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["voice": voiceId, "project": currentProject])
        request.timeoutInterval = 90  // Spawn takes 30-60s

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }

                // Handle 503 (duplicate voice) silently
                if let httpResponse = response as? HTTPURLResponse,
                    httpResponse.statusCode == 503
                {
                    self.spawningVoiceIds.remove(voiceId)
                    // Voice already has a session, switch to it
                    if let existing = self.sessions.first(where: { $0.voice == voiceId }) {
                        self.switchToSession(existing.id)
                    }
                    return
                }

                if let error {
                    self.spawningVoiceIds.remove(voiceId)
                    self.errorMessage = "Spawn failed: \(error.localizedDescription)"
                    return
                }

                guard let data,
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let sid = json["session_id"] as? String
                else {
                    self.spawningVoiceIds.remove(voiceId)
                    if let data,
                        let json = try? JSONSerialization.jsonObject(with: data)
                            as? [String: Any],
                        let errMsg = json["error"] as? String
                    {
                        self.errorMessage = "Spawn failed: \(errMsg)"
                    } else {
                        self.errorMessage = "Failed to spawn session"
                    }
                    return
                }
                self.spawningVoiceIds.remove(voiceId)
                if self.sessionIndex(sid) == nil {
                    self.addSessionFromDict(json)
                }
                // Only auto-switch if still on the home page and not in focus mode
                if self.activeSessionId == nil && !self.showDebug && !self.isFocusMode {
                    self.switchToSession(sid)
                }
            }
        }.resume()
    }

    func terminateSession(_ id: String) {
        guard let baseURL = httpBaseURL() else { return }
        let url = baseURL.appendingPathComponent("api/sessions/\(id)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
        if activeSessionId == id { endLiveActivity() }
        removeSession(id)
    }

    // File upload — mirrors web drag-and-drop POST /api/sessions/:id/upload
    func uploadFile(url: URL) {
        guard let sid = activeSessionId, let baseURL = httpBaseURL() else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            addMessage(sid, role: "system", text: "Upload failed: could not read file")
            return
        }
        let boundary = UUID().uuidString
        var body = Data()
        let filename = url.lastPathComponent
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var req = URLRequest(url: baseURL.appendingPathComponent("api/sessions/\(sid)/upload"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            Task { @MainActor in
                guard let self else { return }
                if let err { self.addMessage(sid, role: "system", text: "Upload error: \(err.localizedDescription)"); return }
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    let msg = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["error"] as? String ?? "Upload failed"
                    self.addMessage(sid, role: "system", text: msg)
                }
            }
        }.resume()
    }

    // Switch to viewing a group chat (sets activeGroupName, loads group history)
    func switchToGroupChat(name: String, firstSessionId: String?) {
        groupMessages = []
        activeGroupName = name
        if let sid = firstSessionId {
            // Update activeSessionId without clearing activeGroupName
            activeSessionId = sid
        }
        fetchGroupHistory(groupName: name)
    }

    // GET /api/groupchats/:name/history → populate groupMessages
    func fetchGroupHistory(groupName: String) {
        guard let baseURL = httpBaseURL() else {
            #if DEBUG
            print("[group-history] no baseURL, aborting")
            #endif
            return
        }
        // If passed a raw groupId (e.g. "gc-abc123"), resolve to display name — server looks up by name
        let resolvedName = groupIdToName[groupName] ?? groupName
        let encoded = resolvedName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? resolvedName
        guard let url = URL(string: baseURL.absoluteString + "/api/groupchats/\(encoded)/history") else {
            #if DEBUG
            print("[group-history] invalid URL for group: \(groupName)")
            #endif
            return
        }
        #if DEBUG
        print("[group-history] fetching \(url)")
        #endif
        URLSession.shared.dataTask(with: url) { [weak self] data, resp, err in
            if let err = err {
                #if DEBUG
                print("[group-history] network error: \(err)")
                #endif
                return
            }
            #if DEBUG
            let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
            print("[group-history] status \(statusCode)")
            #endif
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let msgs = json["messages"] as? [[String: Any]]
            else {
                #if DEBUG
                let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? "nil"
                print("[group-history] parse failed: \(raw)")
                #endif
                return
            }
            #if DEBUG
            print("[group-history] got \(msgs.count) messages")
            #endif
            let parsed = msgs.compactMap { m -> GroupChatMessage? in
                let isBareAck = m["bare_ack"] as? Bool ?? false
                guard let text = m["text"] as? String, (!text.isEmpty || isBareAck)
                else { return nil }
                let id = m["id"] as? String ?? UUID().uuidString
                let senderLabel = m["sender"] as? String ?? ""
                let senderVoice = m["sender_voice"] as? String ?? ""
                let resolvedSender = !senderVoice.isEmpty ? senderVoice :
                    (VOICE_NAME_TO_ID[senderLabel.lowercased()] ?? senderLabel)
                return GroupChatMessage(
                    id: id,
                    role: m["role"] as? String ?? "assistant",
                    text: text,
                    sender: resolvedSender,
                    ts: m["ts"] as? Double ?? 0,
                    parentId: m["parent_id"] as? String,
                    isBareAck: isBareAck
                )
            }
            #if DEBUG
            print("[group-history] parsed \(parsed.count) messages")
            #endif
            Task { @MainActor in
                self?.groupMessages = parsed
            }
        }.resume()
    }

    // POST text message to group chat → /api/groupchats/:name/message
    func sendGroupMessage(_ text: String, groupName: String) {
        guard let baseURL = httpBaseURL() else { return }
        let encoded = groupName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? groupName
        guard let url = URL(string: baseURL.absoluteString + "/api/groupchats/\(encoded)/message") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, _ in
            // Re-fetch history on success so message appears even if WS broadcast is delayed
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                Task { @MainActor in self?.fetchGroupHistory(groupName: groupName) }
            }
        }.resume()
    }

    // Matches web _disbandGroup → DELETE /api/groupchats/:name
    func disbandGroup(_ groupId: String) {
        guard let baseURL = httpBaseURL(),
              let name = groupIdToName[groupId] else { return }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        guard let url = URL(string: baseURL.absoluteString + "/api/groupchats/\(encoded)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }

    func createGroupChat(name: String) {
        guard !name.isEmpty, let baseURL = httpBaseURL() else { return }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/groupchats"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name, "voices": [] as [String]])
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            Task { @MainActor in self?.fetchGroupChats() }
        }.resume()
    }

    func markSessionUnread(_ id: String) {
        guard let idx = sessionIndex(id) else { return }
        sessions[idx].unreadCount = max(sessions[idx].unreadCount, 0) + 1
        if activeSessionId == id { activeSessionId = nil }
    }

    func clearSessionUnread(_ id: String) {
        guard let idx = sessionIndex(id) else { return }
        sessions[idx].unreadCount = 0
        // Persist to server (matches web clearSessionUnread → POST /api/sessions/:id/mark-read)
        guard let baseURL = httpBaseURL() else { return }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/sessions/\(id)/mark-read"))
        req.httpMethod = "POST"
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }

    // Matches web _setRole → POST /api/project-status/:id { role }
    func setSessionRole(_ id: String, role: String) {
        guard let idx = sessionIndex(id), let baseURL = httpBaseURL() else { return }
        sessions[idx].role = role
        var req = URLRequest(url: baseURL.appendingPathComponent("api/project-status/\(id)"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["role": role])
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }

    // Matches web _moveToProject → POST /api/project-status/:id { project, area } + POST /api/agents/:voice/assign
    func moveSessionToProject(_ id: String, project: String) {
        guard let idx = sessionIndex(id), let baseURL = httpBaseURL() else { return }
        let voice = sessions[idx].voice
        let area = sessions[idx].projectArea
        sessions[idx].project = project
        // Optimistically update folders so the sidebar regroups immediately
        for i in folders.indices { folders[i].voices.removeAll { $0 == voice } }
        if let fi = folders.firstIndex(where: { $0.id == project }) {
            if !folders[fi].voices.contains(voice) { folders[fi].voices.append(voice) }
        }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/project-status/\(id)"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["project": project, "area": area])
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
        var req2 = URLRequest(url: baseURL.appendingPathComponent("api/agents/\(voice)/assign"))
        req2.httpMethod = "POST"
        req2.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req2.httpBody = try? JSONSerialization.data(withJSONObject: ["project": project])
        URLSession.shared.dataTask(with: req2) { _, _, _ in }.resume()
    }

    func reorderVoicesInFolder(_ slug: String, voices: [String]) {
        guard let baseURL = httpBaseURL() else { return }
        if let fi = folders.firstIndex(where: { $0.id == slug }) {
            folders[fi].voices = voices
        }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/projects/\(slug)/voices"))
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["voices": voices])
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }

    func moveVoiceToFolder(_ voiceId: String, targetSlug: String) {
        guard let baseURL = httpBaseURL() else { return }
        for i in folders.indices { folders[i].voices.removeAll { $0 == voiceId } }
        if let fi = folders.firstIndex(where: { $0.id == targetSlug }) {
            if !folders[fi].voices.contains(voiceId) { folders[fi].voices.append(voiceId) }
        }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/agents/\(voiceId)/assign"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["project": targetSlug])
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }

    func createFolder(name: String) {
        guard !name.isEmpty, let baseURL = httpBaseURL() else { return }
        let slug = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !slug.isEmpty else { return }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/projects"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["slug": slug, "name": name])
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            Task { @MainActor in self?.fetchProjects() }
        }.resume()
    }

    func renameFolder(_ slug: String, newName: String) {
        guard !newName.isEmpty, let baseURL = httpBaseURL() else { return }
        if let fi = folders.firstIndex(where: { $0.id == slug }) { folders[fi].name = newName }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/projects/\(slug)"))
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": newName])
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            Task { @MainActor in self?.fetchProjects() }
        }.resume()
    }

    func deleteFolder(_ slug: String) {
        guard let baseURL = httpBaseURL() else { return }
        folders.removeAll { $0.id == slug }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/projects/\(slug)"))
        req.httpMethod = "DELETE"
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            Task { @MainActor in self?.fetchProjects() }
        }.resume()
    }

    func markSessionViewing(_ id: String) {
        guard let baseURL = httpBaseURL() else { return }
        let url = baseURL.appendingPathComponent("api/sessions/\(id)/viewing")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    func removeSession(_ id: String) {
        // Clean up audio state for this session (delegates to AudioManager)
        audio.cleanupSession(id)
        clearSessionPrefs(id)
        messagesBySession.removeValue(forKey: id)
        audioBufferBySession.removeValue(forKey: id)
        sessions.removeAll { $0.id == id }
        if activeSessionId == id {
            activeSessionId = sessions.first?.id
        }
    }

    func handleOpenURL(_ url: URL) {
        guard url.scheme == "voicehub" else { return }
        switch url.host {
        case "mic":
            // Tapped mic button in Live Activity - trigger mic action for current session
            if activeSessionId != nil && !pushToTalk {
                micAction()
            }
        default:
            break
        }
    }

    func goHome() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        // Pause audio (don't interrupt) so it resumes on switch back
        audio.pauseCurrentPlaybackForSessionSwitch()
        if isRecording { stopRecording(discard: true) }
        stopThinkingSound()
        audio.stopPlaybackVAD()
        audio.clearSessionSwitchState()
        showPTTTextField = false
        pttPreviewText = ""
        pttTranscriptionError = nil
        clearTranscriptPreview()
        showDebug = false
        activeSessionId = nil
        endLiveActivity()
    }

    func updateSessionVoice(_ voice: String) {
        guard let sid = activeSessionId, let idx = sessionIndex(sid) else { return }
        sessions[idx].voice = voice
        sessions[idx].label = ALL_VOICES.first { $0.id == voice }?.name ?? voice
        saveSessionPrefs(sid, voice: voice, speed: sessions[idx].speed)

        guard let baseURL = httpBaseURL() else { return }
        let url = baseURL.appendingPathComponent("api/sessions/\(sid)/voice")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["voice": voice])
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    func updateSessionSpeed(_ speed: Double) {
        guard let sid = activeSessionId, let idx = sessionIndex(sid) else { return }
        sessions[idx].speed = speed
        saveSessionPrefs(sid, voice: sessions[idx].voice, speed: speed)

        guard let baseURL = httpBaseURL() else { return }
        let url = baseURL.appendingPathComponent("api/sessions/\(sid)/speed")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["speed": speed])
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    // All projects: use server-fetched folders as the authoritative list.
    // session.project is a freeform agent-set display string (may be mixed case),
    // so merging it causes duplicates like "clawmux" + "Clawmux" in the menu.
    var knownProjects: [String] {
        folders.map(\.id)
    }

    func fetchGroupChats() {
        guard let baseURL = httpBaseURL() else { return }
        let url = baseURL.appendingPathComponent("api/groupchats")
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let list = json["groups"] as? [[String: Any]]
            else { return }
            Task { @MainActor in
                guard let self else { return }
                self.knownGroupChats = list.compactMap { g in
                    guard let name = g["name"] as? String else { return nil }
                    let voices = g["voices"] as? [String] ?? []
                    return (name: name, voices: voices)
                }
                // Sync groupId on sessions + build id→name map
                for gc in list {
                    guard let gid = gc["id"] as? String,
                          let name = gc["name"] as? String,
                          let members = gc["members"] as? [[String: Any]]
                    else { continue }
                    self.groupIdToName[gid] = name
                    let memberSessionIds = Set(members.compactMap { $0["session_id"] as? String })
                    for idx in self.sessions.indices {
                        if memberSessionIds.contains(self.sessions[idx].id) {
                            self.sessions[idx].groupId = gid
                        }
                    }
                }
                // Re-resolve activeGroupName if it was set to a raw groupId before map populated
                if let current = self.activeGroupName,
                   let resolvedName = self.groupIdToName[current], resolvedName != current {
                    self.activeGroupName = resolvedName
                    self.fetchGroupHistory(groupName: resolvedName)
                }
            }
        }.resume()
    }

    func fetchProjects() {
        guard let baseURL = httpBaseURL() else { return }
        URLSession.shared.dataTask(with: baseURL.appendingPathComponent("api/projects")) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let projects = json["projects"] as? [String: Any]
            else { return }
            let parsed = projects.compactMap { slug, val -> ProjectFolder? in
                guard let dict = val as? [String: Any],
                      let name = dict["name"] as? String else { return nil }
                let voices = dict["voices"] as? [String] ?? []
                return ProjectFolder(id: slug, name: name, voices: voices)
            }.sorted { $0.name < $1.name }
            Task { @MainActor in self?.folders = parsed }
        }.resume()
    }

    func toggleGroupChatMember(voiceId: String, groupName: String, isMember: Bool) {
        guard let baseURL = httpBaseURL() else { return }
        let action = isMember ? "remove" : "add"
        var req = URLRequest(url: baseURL.appendingPathComponent("api/groupchats/\(groupName)/\(action)"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["voice": voiceId])
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            Task { @MainActor in self?.fetchGroupChats() }
        }.resume()
    }

    // Session Preferences Persistence lives in ClawMuxViewModel+Settings.swift
}
