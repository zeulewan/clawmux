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

private func installVADTap(on input: AVAudioInputNode, format: AVAudioFormat, processor: VADProcessor) {
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

    // Active session UI state
    @Published var statusText = ""
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var isProcessing = false

    // Controls
    @Published var autoRecord = false
    @Published var vadEnabled = true

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

    // MARK: - Init

    override init() {
        self.serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        self.recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording.wav")
        super.init()

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
                options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            print("[audio] Session setup failed: \(error)")
        }
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
                addMessage(sid, role: "assistant", text: t)
            }

        case "user_text":
            if let sid = sessionId, let t = json["text"] as? String {
                addMessage(sid, role: "user", text: t)
                if let idx = sessionIndex(sid) {
                    sessions[idx].isThinking = true
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
        }
        activeSessionId = id

        if let session = activeSession {
            statusText = session.status == "ready" ? "Ready" : "Waiting for Claude..."

            // Handle pending listen
            if session.pendingListen {
                if let idx = sessionIndex(id) {
                    sessions[idx].pendingListen = false
                }
                if autoRecord {
                    startRecording(sessionId: id)
                } else {
                    haptic(.light)
                    statusText = "Tap Record"
                }
            }
        }
    }

    func spawnSession(voiceId: String = "") {
        guard let baseURL = httpBaseURL() else { return }
        let url = baseURL.appendingPathComponent("api/sessions")

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
                else { return }
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

    private func httpBaseURL() -> URL? {
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
        setupAudioSession()

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

        setupAudioSession()

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
