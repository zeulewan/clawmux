import Foundation
import UserNotifications
import Intents

// MARK: - Settings, Preferences, Debug, Monitor, Notifications

extension ClawMuxViewModel {

    // MARK: - Notifications

    func sendNotification(title: String, body: String, sessionId: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(140))
        content.sound = .default
        if let sid = sessionId {
            content.userInfo = ["sessionId": sid]
        }

        // Communication Notification: iMessage-style bubble with sender persona
        let voiceId = sessionId.flatMap { sid in sessions.first { $0.id == sid }?.voice }
        let handle = INPersonHandle(value: voiceId ?? title, type: .unknown)
        let sender = INPerson(
            personHandle: handle,
            nameComponents: nil,
            displayName: title,
            image: nil,
            contactIdentifier: nil,
            customIdentifier: voiceId
        )
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: String(body.prefix(140)),
            speakableGroupName: nil,
            conversationIdentifier: sessionId ?? "clawmux",
            serviceName: nil,
            sender: sender,
            attachments: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)

        do {
            let updated = try content.updating(from: intent)
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: updated, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        } catch {
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    // MARK: - Session Preferences Persistence

    func saveSessionPrefs(_ sessionId: String, voice: String, speed: Double) {
        var prefs = loadAllSessionPrefs()
        prefs[sessionId] = ["voice": voice, "speed": speed]
        if let data = try? JSONSerialization.data(withJSONObject: prefs) {
            UserDefaults.standard.set(data, forKey: "sessionPrefs")
        }
    }

    func loadSessionPrefs(_ sessionId: String) -> (voice: String, speed: Double)? {
        let prefs = loadAllSessionPrefs()
        guard let p = prefs[sessionId],
            let voice = p["voice"] as? String,
            let speed = p["speed"] as? Double
        else { return nil }
        return (voice, speed)
    }

    func loadAllSessionPrefs() -> [String: [String: Any]] {
        guard let data = UserDefaults.standard.data(forKey: "sessionPrefs"),
            let prefs = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return [:] }
        return prefs
    }

    func clearSessionPrefs(_ sessionId: String) {
        var prefs = loadAllSessionPrefs()
        prefs.removeValue(forKey: sessionId)
        if let data = try? JSONSerialization.data(withJSONObject: prefs) {
            UserDefaults.standard.set(data, forKey: "sessionPrefs")
        }
    }

    // MARK: - Server Settings

    func fetchSettings() {
        guard let baseURL = httpBaseURL() else { return }
        let url = baseURL.appendingPathComponent("api/settings")
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            Task { @MainActor in
                guard let self else { return }
                if let model = json["model"] as? String {
                    self.selectedModel = model
                }
                if let autoRecord = json["auto_record"] as? Bool {
                    self.autoRecord = autoRecord
                }
                if let autoEnd = json["auto_end"] as? Bool {
                    self.vadEnabled = autoEnd
                }
                if let autoInterrupt = json["auto_interrupt"] as? Bool {
                    self.autoInterrupt = autoInterrupt
                }
                if let voiceResp = json["voice_responses"] as? Bool {
                    self.voiceResponses = voiceResp
                }
                if let thinkSounds = json["thinking_sounds"] as? Bool {
                    self.soundThinkingAuto = thinkSounds
                }
                if let audioCues = json["audio_cues"] as? Bool {
                    self.soundListeningAuto = audioCues
                }
                if let silent = json["silent_startup"] as? Bool {
                    self.silentStartup = silent
                }
                if let showAgent = json["show_agent_messages"] as? Bool {
                    self.showAgentMessages = showAgent
                }
                if let verbose = json["activity_verbose"] as? Bool {
                    self.verboseMode = verbose
                }
            }
        }.resume()
    }

    func updateSetting(_ key: String, value: Any) {
        guard let baseURL = httpBaseURL() else { return }
        let url = baseURL.appendingPathComponent("api/settings")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [key: value])
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            Task { @MainActor in
                guard let self else { return }
                if let model = json["model"] as? String {
                    self.selectedModel = model
                }
            }
        }.resume()
    }

    func toggleWalkingMode() {
        guard let sid = activeSessionId, let idx = sessionIndex(sid) else { return }
        let newVal = !sessions[idx].walkingMode
        sessions[idx].walkingMode = newVal
        guard let baseURL = httpBaseURL() else { return }
        let url = baseURL.appendingPathComponent("api/agents/\(sid)/walking")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["enabled": newVal])
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    func activateWalkingMode() {
        guard let baseURL = httpBaseURL() else { return }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/walking-mode"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["enabled": true, "voice": "am_puck"])
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = json["session_id"] as? String
            else { return }
            Task { @MainActor in
                guard let self else { return }
                // Switch to Puck's session
                if let puck = self.sessions.first(where: { $0.id == sid }) {
                    self.switchToSession(puck.id)
                }
                self.walkingModeActive = true
                self.pttManager.activateForWalkingMode()
            }
        }.resume()
    }

    func deactivateWalkingMode() {
        walkingModeActive = false
        pttManager.deactivateForWalkingMode()
        guard let baseURL = httpBaseURL() else { return }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/walking-mode"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["enabled": false, "voice": "am_puck"])
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }

    // MARK: - Usage

    func fetchUsage() {
        guard let baseURL = httpBaseURL() else { return }
        let url = baseURL.appendingPathComponent("api/usage")
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            Task { @MainActor in
                guard let self else { return }
                if let fiveHour = json["five_hour"] as? [String: Any] {
                    self.usage5hPct = fiveHour["utilization"] as? Int
                    if let resetsAt = fiveHour["resets_at"] as? String {
                        self.usage5hReset = self.formatResetTime(resetsAt)
                    }
                }
                if let sevenDay = json["seven_day"] as? [String: Any] {
                    self.usage7dPct = sevenDay["utilization"] as? Int
                    if let resetsAt = sevenDay["resets_at"] as? String {
                        self.usage7dReset = self.formatResetTime(resetsAt)
                    }
                }
            }
        }.resume()

        // Fetch context usage for active session
        let ctxUrl = baseURL.appendingPathComponent("api/context")
        URLSession.shared.dataTask(with: ctxUrl) { [weak self] data, _, _ in
            guard let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            Task { @MainActor in
                guard let self, let sid = self.activeSessionId,
                    let ctx = json[sid] as? [String: Any],
                    let pctVal = ctx["percent"] as? Double ?? (ctx["percent"] as? Int).map(Double.init)
                else {
                    await MainActor.run { self?.contextPct = nil }
                    return
                }
                self.contextPct = Int(pctVal.rounded())
            }
        }.resume()
    }

    func formatResetTime(_ isoStr: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: isoStr) ?? ISO8601DateFormatter().date(from: isoStr) else { return "" }
        let diff = date.timeIntervalSinceNow
        if diff <= 0 { return "now" }
        let hrs = Int(diff) / 3600
        let mins = (Int(diff) % 3600) / 60
        if hrs > 24 { return "\(hrs / 24)d" }
        if hrs > 0 { return "\(hrs)h \(mins)m" }
        return "\(mins)m"
    }

    // MARK: - Monitor

    /// Start a monitor panel. Returns (key, url) on success.
    func startMonitor(type: String, id: String) async -> (key: String, url: String)? {
        guard let baseURL = httpBaseURL() else {
            print("[monitor] no baseURL")
            return nil
        }
        let endpoint = baseURL.appendingPathComponent("api/monitor/start")
        print("[monitor] POST \(endpoint) type=\(type) id=\(id)")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["type": type, "id": id])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let raw = String(data: data, encoding: .utf8) ?? "nil"
            print("[monitor] status=\(status) body=\(raw)")
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let key = json["key"] as? String,
                  let url = json["url"] as? String
            else {
                print("[monitor] parse failed — missing 'key' or 'url' in response")
                return nil
            }
            print("[monitor] success key=\(key) url=\(url)")
            return (key: key, url: url)
        } catch {
            print("[monitor] request failed: \(error)")
            return nil
        }
    }

    func stopMonitor(key: String) {
        guard let baseURL = httpBaseURL() else { return }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/monitor/stop"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["key": key])
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }

    // MARK: - Debug

    func startDebugRefresh() {
        stopDebugRefresh()
        fetchDebugInfo()
        debugRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.fetchDebugInfo() }
        }
    }

    func stopDebugRefresh() {
        debugRefreshTimer?.invalidate()
        debugRefreshTimer = nil
    }

    func reloadHub() {
        guard let baseURL = httpBaseURL() else { return }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/shutdown"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["mode": "reload"])
        URLSession.shared.dataTask(with: req).resume()
    }

    func fetchDebugInfo() {
        guard let baseURL = httpBaseURL() else { return }

        // Fetch /api/debug
        let debugURL = baseURL.appendingPathComponent("api/debug")
        URLSession.shared.dataTask(with: debugURL) { [weak self] data, _, _ in
            guard let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            Task { @MainActor in
                guard let self else { return }

                // Hub
                if let hub = json["hub"] as? [String: Any] {
                    self.debugHub = DebugHubInfo(
                        port: hub["port"] as? Int ?? 0,
                        uptimeSeconds: hub["uptime_seconds"] as? Int ?? 0,
                        browserConnected: hub["browser_connected"] as? Bool ?? false,
                        clientCount: hub["client_count"] as? Int ?? 0,
                        sessionCount: hub["session_count"] as? Int ?? 0
                    )
                }

                // Services
                if let svcs = json["services"] as? [String: [String: Any]] {
                    self.debugServices = svcs.map { name, info in
                        DebugService(
                            name: name,
                            url: info["url"] as? String ?? "",
                            status: info["status"] as? String ?? "unknown",
                            detail: info["status"] as? String == "up"
                                ? "HTTP \(info["code"] as? Int ?? 0)"
                                : (info["error"] as? String ?? "")
                        )
                    }.sorted { $0.name < $1.name }
                }

                // Sessions
                if let sess = json["sessions"] as? [[String: Any]] {
                    self.debugSessions = sess.map { s in
                        DebugHubSession(
                            sessionId: s["session_id"] as? String ?? "?",
                            voice: s["voice"] as? String ?? "?",
                            project: s["project"] as? String ?? "",
                            projectRepo: s["project_repo"] as? String ?? "",
                            workDir: s["work_dir"] as? String ?? "",
                            state: s["state"] as? String ?? s["status"] as? String ?? "?",
                            mcpConnected: s["mcp_connected"] as? Bool ?? false,
                            idleSeconds: s["idle_seconds"] as? Int ?? 0,
                            ageSeconds: s["age_seconds"] as? Int ?? 0
                        )
                    }
                }

                // tmux
                if let tmux = json["tmux_sessions"] as? [[String: Any]] {
                    self.debugTmux = tmux.map { t in
                        let created = t["created"] as? Int ?? 0
                        let date = Date(timeIntervalSince1970: TimeInterval(created))
                        let fmt = DateFormatter()
                        fmt.timeStyle = .medium
                        return DebugTmuxSession(
                            name: t["name"] as? String ?? "?",
                            isVoice: t["is_voice"] as? Bool ?? false,
                            windows: t["windows"] as? Int ?? 0,
                            attached: t["attached"] as? Bool ?? false,
                            created: fmt.string(from: date)
                        )
                    }
                }

                // System
                if let sys = json["system"] as? [String: Any] {
                    self.debugSystem = DebugSystemInfo(
                        cpuPercent: sys["cpu_percent"] as? Double,
                        ramUsedGB: sys["ram_used_gb"] as? Double ?? 0,
                        ramTotalGB: sys["ram_total_gb"] as? Double ?? 0,
                        ramPercent: sys["ram_percent"] as? Double ?? 0,
                        gpuPercent: sys["gpu_percent"] as? Int,
                        vramUsedMB: sys["vram_used_mb"] as? Int ?? 0,
                        vramTotalMB: sys["vram_total_mb"] as? Int ?? 0,
                        gpuTempC: sys["gpu_temp_c"] as? Int
                    )
                }

                let fmt = DateFormatter()
                fmt.timeStyle = .medium
                self.debugLastUpdated = "Updated " + fmt.string(from: Date())
            }
        }.resume()

        // Fetch /api/debug/log
        let logURL = baseURL.appendingPathComponent("api/debug/log")
        URLSession.shared.dataTask(with: logURL) { [weak self] data, _, _ in
            guard let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let lines = json["lines"] as? [String]
            else { return }
            Task { @MainActor in
                self?.debugLog = lines
            }
        }.resume()

        // Fetch /api/debug/status
        let statusURL = baseURL.appendingPathComponent("api/debug/status")
        URLSession.shared.dataTask(with: statusURL) { [weak self] data, _, _ in
            guard let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let output = json["output"] as? String
            else { return }
            Task { @MainActor in
                self?.debugStatus = output
            }
        }.resume()
    }
}
