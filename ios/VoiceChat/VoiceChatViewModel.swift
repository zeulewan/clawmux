import AVFoundation
import Foundation
import UIKit

// MARK: - Models

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: String  // "user", "assistant", "system"
    let text: String
}

struct VoiceSession: Identifiable {
    let id: String
    var label: String
    var voice: String
    var speed: Double
    var status: String  // "starting", "ready", "active"
    var messages: [ChatMessage] = []
    var tmuxSession: String = ""
    var isThinking: Bool = false
    var pendingListen: Bool = false
}

struct VoiceInfo: Identifiable {
    let id: String
    let name: String
}

let ALL_VOICES: [VoiceInfo] = [
    VoiceInfo(id: "af_sky", name: "Sky"),
    VoiceInfo(id: "af_alloy", name: "Alloy"),
    VoiceInfo(id: "af_sarah", name: "Sarah"),
    VoiceInfo(id: "am_adam", name: "Adam"),
    VoiceInfo(id: "am_echo", name: "Echo"),
    VoiceInfo(id: "am_onyx", name: "Onyx"),
    VoiceInfo(id: "bm_fable", name: "Fable"),
]

let SPEED_OPTIONS: [(label: String, value: Double)] = [
    ("0.75x", 0.75), ("1x", 1.0), ("1.25x", 1.25), ("1.5x", 1.5), ("2x", 2.0),
]

// MARK: - VAD Tap Helper (must be outside @MainActor to avoid isolation inheritance)

private func installVADTap(
    on input: AVAudioInputNode, format: AVAudioFormat, processor: VADProcessor
) {
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
        processor.processBuffer(buffer)
    }
}

// MARK: - VAD Processor (runs on audio realtime thread)

final class VADProcessor: @unchecked Sendable {
    private let onSilenceDetected: @Sendable () -> Void
    private var detectedSpeech = false
    private var silenceStart: Date?
    private let silenceThreshold: Float = 10
    private let silenceDuration: TimeInterval = 3.0

    init(onSilenceDetected: @escaping @Sendable () -> Void) {
        self.onSilenceDetected = onSilenceDetected
    }

    func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(count)) * 200

        if rms < silenceThreshold {
            if silenceStart == nil { silenceStart = Date() }
            if detectedSpeech,
                let start = silenceStart,
                Date().timeIntervalSince(start) > silenceDuration
            {
                detectedSpeech = false
                silenceStart = nil
                onSilenceDetected()
            }
        } else {
            silenceStart = nil
            detectedSpeech = true
        }
    }
}

// MARK: - Tone Player (audio cues matching web client)

final class TonePlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    private func ensureRunning() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
            player.play()
        } catch {
            print("[tone] Engine start failed: \(error)")
        }
    }

    func play(_ tones: [(freq: Double, dur: Double, delay: Double, gain: Float)]) {
        let sr = format.sampleRate
        guard let end = tones.map({ $0.delay + $0.dur }).max(), end > 0 else { return }
        let count = AVAudioFrameCount(end * sr) + 1
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return }
        buf.frameLength = count
        let s = buf.floatChannelData![0]
        for i in 0..<Int(count) { s[i] = 0 }

        for t in tones {
            let start = Int(t.delay * sr)
            let len = Int(t.dur * sr)
            for i in 0..<len where start + i < Int(count) {
                let time = Double(i) / sr
                let env = t.gain * Float(max(0.001, exp(-time * 5.0 / t.dur)))
                s[start + i] += env * sinf(Float(2.0 * .pi * t.freq * time))
            }
        }

        ensureRunning()
        player.scheduleBuffer(buf, completionHandler: nil)
    }

    // Ascending two-tone: your turn to speak
    func cueListening() {
        play([(660, 0.12, 0, 0.15), (880, 0.15, 0.1, 0.15)])
    }

    // Single soft low tone: processing
    func cueProcessing() {
        play([(440, 0.2, 0, 0.08)])
    }

    // Three-note chime: session connected
    func cueSessionReady() {
        play([(523, 0.1, 0, 0.15), (659, 0.1, 0.1, 0.15), (784, 0.15, 0.2, 0.15)])
    }

    // Double-tick: thinking
    func thinkingTick() {
        play([(1200, 0.03, 0, 0.06), (900, 0.03, 0.08, 0.04)])
    }
}

// MARK: - Debug Data Models

struct DebugHubInfo {
    var port = 0
    var uptimeSeconds = 0
    var browserConnected = false
    var sessionCount = 0
}

struct DebugService: Identifiable {
    let id = UUID()
    let name: String
    let url: String
    let status: String
    let detail: String
}

struct DebugHubSession: Identifiable {
    var id: String { sessionId }
    let sessionId: String
    let voice: String
    let status: String
    let mcpConnected: Bool
    let idleSeconds: Int
    let ageSeconds: Int
}

struct DebugTmuxSession: Identifiable {
    let id = UUID()
    let name: String
    let isVoice: Bool
    let windows: Int
    let attached: Bool
    let created: String
}

// MARK: - ViewModel

@MainActor
final class VoiceChatViewModel: NSObject, ObservableObject {

    // Connection
    @Published var isConnected = false
    @Published var showSettings = false
    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }

    // Sessions
    @Published var sessions: [VoiceSession] = []
    @Published var activeSessionId: String?
    @Published var spawningVoiceId: String?

    // Active session UI state
    @Published var statusText = ""
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var isProcessing = false

    // Controls
    @Published var autoRecord = false
    @Published var vadEnabled = true

    // Debug
    @Published var showDebug = false
    @Published var debugHub = DebugHubInfo()
    @Published var debugServices: [DebugService] = []
    @Published var debugSessions: [DebugHubSession] = []
    @Published var debugTmux: [DebugTmuxSession] = []
    @Published var debugLog: [String] = []
    @Published var debugLastUpdated = ""

    // Computed
    var activeSession: VoiceSession? {
        guard let id = activeSessionId else { return nil }
        return sessions.first { $0.id == id }
    }

    var activeMessages: [ChatMessage] {
        activeSession?.messages ?? []
    }

    var activeVoice: String {
        get { activeSession?.voice ?? "af_sky" }
        set { updateSessionVoice(newValue) }
    }

    var activeSpeed: Double {
        get { activeSession?.speed ?? 1.0 }
        set { updateSessionSpeed(newValue) }
    }

    // Private
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var audioPlayer: AVAudioPlayer?
    private var audioRecorder: AVAudioRecorder?
    private var reconnectWork: DispatchWorkItem?
    private let recordingURL: URL
    private var playingSessionId: String?
    private var recordingSessionId: String?
    private lazy var tonePlayer = TonePlayer()
    private var thinkingSoundTimer: Timer?
    private var debugRefreshTimer: Timer?

    // MARK: - Init

    override init() {
        self.serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        self.recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording.wav")
        super.init()

        setupAudioSession()

        if serverURL.isEmpty {
            showSettings = true
        } else {
            connect()
        }
    }

    deinit {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()
    }

    // MARK: - Helpers

    private func sessionIndex(_ id: String) -> Int? {
        sessions.firstIndex { $0.id == id }
    }

    private func addMessage(_ sessionId: String, role: String, text: String) {
        guard let idx = sessionIndex(sessionId) else { return }
        sessions[idx].messages.append(ChatMessage(role: role, text: text))
    }

    // MARK: - Audio Session

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord, mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
            try session.setActive(true)
        } catch {
            print("[audio] Session setup failed: \(error)")
        }
    }

    // MARK: - Thinking Sound

    func startThinkingSound() {
        stopThinkingSound()
        tonePlayer.thinkingTick()
        thinkingSoundTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                self?.tonePlayer.thinkingTick()
            }
        }
    }

    func stopThinkingSound() {
        thinkingSoundTimer?.invalidate()
        thinkingSoundTimer = nil
    }

    // MARK: - WebSocket

    func connect() {
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

        statusText = "Connecting..."
        urlSession = URLSession(
            configuration: .default, delegate: self, delegateQueue: nil)
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()
    }

    func disconnect() {
        reconnectWork?.cancel()
        reconnectWork = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isConnected = false
        stopThinkingSound()
    }

    private func scheduleReconnect() {
        reconnectWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.connect() }
        }
        reconnectWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
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

    private func handleDisconnect() {
        isConnected = false
        isRecording = false
        isPlaying = false
        isProcessing = false
        statusText = "Disconnected"
        stopThinkingSound()
        scheduleReconnect()
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
            let string = String(data: data, encoding: .utf8)
        else { return }
        webSocketTask?.send(.string(string)) { error in
            if let error { print("[ws] Send error: \(error)") }
        }
    }

    // MARK: - Hub Protocol

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
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
                for s in list {
                    if let sid = s["session_id"] as? String, sessionIndex(sid) == nil {
                        addSessionFromDict(s)
                    }
                }
            }

        case "session_spawned":
            if let s = json["session"] as? [String: Any],
                let sid = s["session_id"] as? String,
                sessionIndex(sid) == nil
            {
                // Clear spawning state for the voice
                if let voice = s["voice"] as? String, spawningVoiceId == voice {
                    spawningVoiceId = nil
                }
                addSessionFromDict(s)
                switchToSession(sid)
            }

        case "session_terminated":
            if let sid = sessionId {
                removeSession(sid)
            }

        case "session_status":
            if let sid = sessionId, let status = json["status"] as? String,
                let idx = sessionIndex(sid)
            {
                sessions[idx].status = status
                if status == "ready" {
                    addMessage(sid, role: "system", text: "Claude connected.")
                    tonePlayer.cueSessionReady()
                    haptic(.success)
                }
            }

        case "error":
            let msg = json["message"] as? String ?? "Unknown error"
            statusText = "Error: \(msg)"

        // Session-scoped messages
        case "assistant_text":
            if let sid = sessionId, let t = json["text"] as? String {
                if let idx = sessionIndex(sid) {
                    sessions[idx].isThinking = false
                }
                stopThinkingSound()
                addMessage(sid, role: "assistant", text: t)
            }

        case "user_text":
            if let sid = sessionId, let t = json["text"] as? String {
                addMessage(sid, role: "user", text: t)
                if let idx = sessionIndex(sid) {
                    sessions[idx].isThinking = true
                }
                if sid == activeSessionId {
                    startThinkingSound()
                }
            }

        case "audio":
            if let sid = sessionId, let b64 = json["data"] as? String,
                let audioData = Data(base64Encoded: b64)
            {
                if let idx = sessionIndex(sid) {
                    sessions[idx].status = "active"
                }
                if sid == activeSessionId {
                    playAudio(sid, data: audioData)
                }
            }

        case "listening":
            if let sid = sessionId {
                if sid == activeSessionId {
                    tonePlayer.cueListening()
                    haptic(.light)
                    if autoRecord {
                        startRecording(sessionId: sid)
                    } else {
                        if let idx = sessionIndex(sid) {
                            sessions[idx].pendingListen = true
                        }
                        statusText = "Tap Record"
                    }
                } else {
                    if let idx = sessionIndex(sid) {
                        sessions[idx].pendingListen = true
                    }
                }
            }

        case "status":
            if let sid = sessionId, let t = json["text"] as? String {
                if sid == activeSessionId {
                    statusText = t
                }
            }

        case "done":
            if let sid = sessionId, let idx = sessionIndex(sid) {
                sessions[idx].status = "ready"
                if sid == activeSessionId {
                    statusText = "Ready"
                    isProcessing = false
                }
            }

        case "session_ended":
            if let sid = sessionId {
                addMessage(sid, role: "system", text: "Session ended.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.terminateSession(sid)
                }
            }

        default:
            break
        }
    }

    // MARK: - Session Management

    private func addSessionFromDict(_ dict: [String: Any]) {
        let sid = dict["session_id"] as? String ?? UUID().uuidString
        let voice = dict["voice"] as? String ?? "af_sky"
        let label =
            ALL_VOICES.first { $0.id == voice }?.name ?? dict["label"] as? String ?? "Session"
        let status = dict["status"] as? String ?? "starting"
        let tmux = dict["tmux_session"] as? String ?? sid
        let isReady = status == "ready" || dict["mcp_connected"] as? Bool == true

        var session = VoiceSession(
            id: sid, label: label, voice: voice, speed: 1.0,
            status: isReady ? "ready" : status, tmuxSession: tmux)

        if isReady {
            session.messages.append(ChatMessage(role: "system", text: "Claude connected."))
        } else {
            session.messages.append(
                ChatMessage(role: "system", text: "Session started. Waiting for Claude..."))
        }

        sessions.append(session)
    }

    func switchToSession(_ id: String) {
        if activeSessionId != id {
            // Stop audio/recording from previous session
            if isPlaying { interruptPlayback() }
            if isRecording { stopRecording(discard: true) }
            stopThinkingSound()
        }
        activeSessionId = id
        showDebug = false

        if let session = activeSession {
            statusText = session.status == "ready" ? "Ready" : "Waiting for Claude..."

            // Resume thinking sound if session is thinking
            if session.isThinking {
                startThinkingSound()
            }

            // Handle pending listen
            if session.pendingListen {
                if let idx = sessionIndex(id) {
                    sessions[idx].pendingListen = false
                }
                if autoRecord {
                    tonePlayer.cueListening()
                    startRecording(sessionId: id)
                } else {
                    tonePlayer.cueListening()
                    haptic(.light)
                    statusText = "Tap Record"
                }
            }
        }
    }

    func spawnSession(voiceId: String = "") {
        guard let baseURL = httpBaseURL() else { return }
        let url = baseURL.appendingPathComponent("api/sessions")

        spawningVoiceId = voiceId.isEmpty ? nil : voiceId

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["voice": voiceId])

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            Task { @MainActor in
                guard let self, let data,
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let sid = json["session_id"] as? String
                else {
                    self?.spawningVoiceId = nil
                    return
                }
                self.spawningVoiceId = nil
                if self.sessionIndex(sid) == nil {
                    self.addSessionFromDict(json)
                }
                self.switchToSession(sid)
            }
        }.resume()
    }

    func terminateSession(_ id: String) {
        guard let baseURL = httpBaseURL() else { return }
        let url = baseURL.appendingPathComponent("api/sessions/\(id)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
        removeSession(id)
    }

    private func removeSession(_ id: String) {
        sessions.removeAll { $0.id == id }
        if activeSessionId == id {
            activeSessionId = sessions.first?.id
        }
    }

    private func updateSessionVoice(_ voice: String) {
        guard let sid = activeSessionId, let idx = sessionIndex(sid) else { return }
        sessions[idx].voice = voice
        sessions[idx].label = ALL_VOICES.first { $0.id == voice }?.name ?? voice

        guard let baseURL = httpBaseURL() else { return }
        let url = baseURL.appendingPathComponent("api/sessions/\(sid)/voice")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["voice": voice])
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    private func updateSessionSpeed(_ speed: Double) {
        guard let sid = activeSessionId, let idx = sessionIndex(sid) else { return }
        sessions[idx].speed = speed

        guard let baseURL = httpBaseURL() else { return }
        let url = baseURL.appendingPathComponent("api/sessions/\(sid)/speed")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["speed": speed])
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    func httpBaseURL() -> URL? {
        var base = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.hasPrefix("http://") && !base.hasPrefix("https://") {
            base = "https://" + base
        }
        return URL(string: base)
    }

    // MARK: - Audio Playback

    private func playAudio(_ sessionId: String, data: Data) {
        statusText = "Playing..."
        isPlaying = true
        playingSessionId = sessionId

        do {
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = self
            audioPlayer?.play()
        } catch {
            print("[audio] Playback error: \(error)")
            statusText = "Audio error"
            isPlaying = false
            sendJSON([
                "session_id": sessionId,
                "type": "playback_done",
            ])
        }
    }

    func interruptPlayback() {
        guard isPlaying, let sid = playingSessionId else { return }
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        playingSessionId = nil
        haptic(.medium)
        sendJSON(["session_id": sid, "type": "playback_done"])
    }

    // MARK: - Recording

    func startRecording(sessionId: String? = nil) {
        let sid = sessionId ?? activeSessionId
        guard let sid else { return }
        recordingSessionId = sid

        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self, granted else {
                    self?.statusText = "Microphone access denied"
                    return
                }
                self.beginRecording()
            }
        }
    }

    private func beginRecording() {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: recordingURL, settings: settings)
            audioRecorder?.record()
            isRecording = true
            statusText = "Recording..."
            haptic(.light)

            if vadEnabled {
                startVAD()
            }
        } catch {
            print("[mic] Recording error: \(error)")
            statusText = "Recording error"
        }
    }

    func stopRecording(discard: Bool = false) {
        guard let recorder = audioRecorder, recorder.isRecording else { return }
        recorder.stop()
        audioRecorder = nil
        isRecording = false
        stopVAD()

        guard !discard, let sid = recordingSessionId else {
            recordingSessionId = nil
            return
        }

        statusText = "Processing..."
        isProcessing = true
        tonePlayer.cueProcessing()
        haptic(.light)

        if let audioData = try? Data(contentsOf: recordingURL) {
            let b64 = audioData.base64EncodedString()
            sendJSON(["session_id": sid, "type": "audio", "data": b64])
        }
        recordingSessionId = nil
    }

    func cancelRecording() {
        guard isRecording, let sid = recordingSessionId else { return }
        stopRecording(discard: true)
        // Send empty audio so hub doesn't hang
        sendJSON(["session_id": sid, "type": "audio", "data": ""])
        statusText = "Recording cancelled"
    }

    // Mic button action: context-dependent
    func micAction() {
        if isPlaying {
            interruptPlayback()
        } else if isRecording {
            stopRecording()
        } else if let sid = activeSessionId {
            // Clear pending listen flag
            if let idx = sessionIndex(sid), sessions[idx].pendingListen {
                sessions[idx].pendingListen = false
            }
            startRecording(sessionId: sid)
        }
    }

    // MARK: - VAD (Voice Activity Detection)

    private var vadAudioEngine: AVAudioEngine?
    private var vadProcessor: VADProcessor?

    private func startVAD() {
        stopVAD()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        let processor = VADProcessor { [weak self] in
            Task { @MainActor in
                self?.stopRecording()
            }
        }
        vadProcessor = processor

        installVADTap(on: input, format: format, processor: processor)

        do {
            try engine.start()
            vadAudioEngine = engine
        } catch {
            print("[vad] Engine start failed: \(error)")
        }
    }

    private func stopVAD() {
        vadAudioEngine?.inputNode.removeTap(onBus: 0)
        vadAudioEngine?.stop()
        vadAudioEngine = nil
        vadProcessor = nil
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
                            status: s["status"] as? String ?? "?",
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
    }

    // MARK: - Haptics

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    private func haptic(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}

// MARK: - URLSessionWebSocketDelegate

extension VoiceChatViewModel: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor in
            self.isConnected = true
            self.statusText = "Connected"
            self.receiveMessage()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor in self.handleDisconnect() }
    }

    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if error != nil {
            Task { @MainActor in self.handleDisconnect() }
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension VoiceChatViewModel: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer, successfully flag: Bool
    ) {
        Task { @MainActor in
            let sid = self.playingSessionId ?? ""
            self.isPlaying = false
            self.playingSessionId = nil
            if !sid.isEmpty {
                self.sendJSON(["session_id": sid, "type": "playback_done"])
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(
        _ player: AVAudioPlayer, error: (any Error)?
    ) {
        Task { @MainActor in
            let sid = self.playingSessionId ?? ""
            self.isPlaying = false
            self.playingSessionId = nil
            self.statusText = "Audio decode error"
            if !sid.isEmpty {
                self.sendJSON(["session_id": sid, "type": "playback_done"])
            }
        }
    }
}

// MARK: - Helpers

func formatDuration(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    return "\(h)h \(m)m"
}
