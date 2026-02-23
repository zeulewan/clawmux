import ActivityKit
import AVFoundation
import Foundation
import UIKit
import UserNotifications

// MARK: - Models

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: String  // "user", "assistant", "system"
    let text: String
}

enum SessionStatus: String {
    case starting, ready, active
}

struct VoiceSession: Identifiable {
    let id: String
    var label: String
    var voice: String
    var speed: Double
    var status: SessionStatus = .starting
    var messages: [ChatMessage] = []
    var tmuxSession: String = ""
    var isThinking: Bool = false
    var pendingListen: Bool = false
    var statusText: String = ""
    var audioBuffer: [Data] = []
    var project: String = ""
    var projectArea: String = ""
    var unreadCount: Int = 0
    var awaitingInput: Bool = false
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
    private var startedAt: Date?
    private let silenceThreshold: Float
    private let silenceDuration: TimeInterval
    // Ignore the first N seconds so audio cues played through the speaker
    // don't get picked up by the mic and falsely trigger speech detection
    private let gracePeriod: TimeInterval = 0.8

    init(
        silenceThreshold: Float = 10,
        silenceDuration: TimeInterval = 3.0,
        onSilenceDetected: @escaping @Sendable () -> Void
    ) {
        self.silenceThreshold = silenceThreshold
        self.silenceDuration = silenceDuration
        self.onSilenceDetected = onSilenceDetected
    }

    func processBuffer(_ buffer: AVAudioPCMBuffer) {
        let now = Date()
        if startedAt == nil { startedAt = now }
        // Skip processing during grace period so cue tones don't register as speech
        guard now.timeIntervalSince(startedAt!) >= gracePeriod else { return }

        guard let data = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(count)) * 200

        if rms < silenceThreshold {
            if silenceStart == nil { silenceStart = now }
            if detectedSpeech,
                let start = silenceStart,
                now.timeIntervalSince(start) > silenceDuration
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

// MARK: - Playback VAD Processor (for auto-interrupt during playback)

final class PlaybackVADProcessor: @unchecked Sendable {
    private let onSpeechDetected: @Sendable () -> Void
    private var speechStart: Date?
    private let speechThreshold: Float = 25
    private let speechDuration: TimeInterval = 0.3

    init(onSpeechDetected: @escaping @Sendable () -> Void) {
        self.onSpeechDetected = onSpeechDetected
    }

    func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(count)) * 200

        if rms > speechThreshold {
            if speechStart == nil { speechStart = Date() }
            if let start = speechStart,
                Date().timeIntervalSince(start) > speechDuration
            {
                speechStart = nil
                onSpeechDetected()
            }
        } else {
            speechStart = nil
        }
    }
}

private func installPlaybackVADTap(
    on input: AVAudioInputNode, format: AVAudioFormat, processor: PlaybackVADProcessor
) {
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
        processor.processBuffer(buffer)
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
        play([(1200, 0.03, 0, 0.025), (900, 0.03, 0.08, 0.015)])
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
final class VoiceHubViewModel: NSObject, ObservableObject {

    // Connection
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var showSettings = false
    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }

    // Sessions
    @Published var sessions: [VoiceSession] = []
    @Published var activeSessionId: String? {
        didSet { UserDefaults.standard.set(activeSessionId, forKey: "activeSessionId") }
    }
    @Published var spawningVoiceIds: Set<String> = []
    @Published var errorMessage: String?
    @Published var ttsPlayingMessageId: UUID?

    // Active session UI state
    @Published var statusText = ""
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var isProcessing = false
    @Published var audioLevels: [CGFloat] = []

    // Controls
    // Input mode: "auto", "ptt", "typing"
    @Published var inputMode: String {
        didSet {
            UserDefaults.standard.set(inputMode, forKey: "inputMode")
            if let sid = activeSessionId {
                sendJSON(["session_id": sid, "type": "set_mode", "mode": inputMode == "typing" ? "text" : "voice"])
            }
            // Clear mute when leaving auto mode (mute is auto-only)
            if inputMode != "auto" { micMuted = false }
            // Update status text for the new mode
            if let sid = activeSessionId, let idx = sessionIndex(sid) {
                if sessions[idx].pendingListen {
                    let text = inputMode == "typing" ? "Type a message"
                        : inputMode == "ptt" ? "Hold to Talk" : "Tap Record"
                    updateStatusText(text, for: sid)
                } else if !sessions[idx].isThinking && !isRecording && !isPlaying && !isProcessing {
                    updateStatusText("Ready", for: sid)
                }
            }
            // Manage live activity based on per-mode toggle
            endLiveActivity()
            if let sid = activeSessionId {
                startLiveActivity(sessionId: sid)
            }
        }
    }
    var pushToTalk: Bool { inputMode == "ptt" }
    var typingMode: Bool { inputMode == "typing" }
    var isAutoMode: Bool { inputMode == "auto" }

    // These only take effect in auto mode
    var effectiveAutoRecord: Bool { isAutoMode && autoRecord }
    var effectiveVAD: Bool { isAutoMode && vadEnabled }
    var effectiveAutoInterrupt: Bool { isAutoMode && autoInterrupt }

    // True when the toggle is off and the agent is actively thinking/processing
    var recordBlockedByThinking: Bool {
        guard !allowRecordWhileThinking else { return false }
        return activeSession?.isThinking == true || isProcessing
    }

    @Published var autoRecord: Bool {
        didSet { UserDefaults.standard.set(autoRecord, forKey: "autoRecord") }
    }
    @Published var vadEnabled: Bool {
        didSet { UserDefaults.standard.set(vadEnabled, forKey: "vadEnabled") }
    }
    @Published var autoInterrupt: Bool {
        didSet { UserDefaults.standard.set(autoInterrupt, forKey: "autoInterrupt") }
    }
    // VAD tuning
    @Published var vadSilenceDuration: Double {
        didSet { UserDefaults.standard.set(vadSilenceDuration, forKey: "vadSilenceDuration") }
    }
    @Published var vadThreshold: Double {
        didSet { UserDefaults.standard.set(vadThreshold, forKey: "vadThreshold") }
    }
    // Allow recording while agent is still thinking/generating
    // When on: audio is queued and used immediately, skipping the agent's spoken response
    // When off: record button is blocked until agent finishes and sends "listening"
    @Published var allowRecordWhileThinking: Bool {
        didSet { UserDefaults.standard.set(allowRecordWhileThinking, forKey: "allowRecordWhileThinking") }
    }
    @Published var micMuted: Bool {
        didSet {
            UserDefaults.standard.set(micMuted, forKey: "micMuted")
            if micMuted { handleMuteActivated() }
        }
    }
    @Published var backgroundMode: Bool {
        didSet { UserDefaults.standard.set(backgroundMode, forKey: "backgroundMode") }
    }

    // Sound toggles — per mode
    @Published var soundThinkingAuto: Bool {
        didSet { UserDefaults.standard.set(soundThinkingAuto, forKey: "soundThinkingAuto") }
    }
    @Published var soundThinkingPTT: Bool {
        didSet { UserDefaults.standard.set(soundThinkingPTT, forKey: "soundThinkingPTT") }
    }
    @Published var soundListeningAuto: Bool {
        didSet { UserDefaults.standard.set(soundListeningAuto, forKey: "soundListeningAuto") }
    }
    @Published var soundProcessingAuto: Bool {
        didSet { UserDefaults.standard.set(soundProcessingAuto, forKey: "soundProcessingAuto") }
    }
    @Published var soundReadyAuto: Bool {
        didSet { UserDefaults.standard.set(soundReadyAuto, forKey: "soundReadyAuto") }
    }
    @Published var soundReadyPTT: Bool {
        didSet { UserDefaults.standard.set(soundReadyPTT, forKey: "soundReadyPTT") }
    }

    // Haptics toggles — per mode
    @Published var hapticsRecordingAuto: Bool {
        didSet { UserDefaults.standard.set(hapticsRecordingAuto, forKey: "hapticsRecordingAuto") }
    }
    @Published var hapticsRecordingPTT: Bool {
        didSet { UserDefaults.standard.set(hapticsRecordingPTT, forKey: "hapticsRecordingPTT") }
    }
    @Published var hapticsPlaybackAuto: Bool {
        didSet { UserDefaults.standard.set(hapticsPlaybackAuto, forKey: "hapticsPlaybackAuto") }
    }
    @Published var hapticsPlaybackPTT: Bool {
        didSet { UserDefaults.standard.set(hapticsPlaybackPTT, forKey: "hapticsPlaybackPTT") }
    }
    @Published var hapticsSend: Bool {
        didSet { UserDefaults.standard.set(hapticsSend, forKey: "hapticsSend") }
    }
    @Published var hapticsSessionAuto: Bool {
        didSet { UserDefaults.standard.set(hapticsSessionAuto, forKey: "hapticsSessionAuto") }
    }
    @Published var hapticsSessionPTT: Bool {
        didSet { UserDefaults.standard.set(hapticsSessionPTT, forKey: "hapticsSessionPTT") }
    }
    @Published var hapticsSessionTyping: Bool {
        didSet { UserDefaults.standard.set(hapticsSessionTyping, forKey: "hapticsSessionTyping") }
    }

    // Notification toggles — per mode
    @Published var notifyAuto: Bool {
        didSet { UserDefaults.standard.set(notifyAuto, forKey: "notifyAuto") }
    }
    @Published var notifyPTT: Bool {
        didSet { UserDefaults.standard.set(notifyPTT, forKey: "notifyPTT") }
    }
    @Published var notifyTyping: Bool {
        didSet { UserDefaults.standard.set(notifyTyping, forKey: "notifyTyping") }
    }

    // Live Activity toggles — per mode
    @Published var liveActivityAuto: Bool {
        didSet {
            UserDefaults.standard.set(liveActivityAuto, forKey: "liveActivityAuto")
            if !liveActivityAuto && isAutoMode { endLiveActivity() }
        }
    }
    @Published var liveActivityPTT: Bool {
        didSet {
            UserDefaults.standard.set(liveActivityPTT, forKey: "liveActivityPTT")
            if !liveActivityPTT && pushToTalk { endLiveActivity() }
        }
    }

    @Published var selectedModel: String = "opus"
    @Published var typingText = ""

    // PTT preview/keyboard mode (swipe right on mic)
    @Published var showPTTTextField = false
    @Published var pttPreviewText = ""
    @Published var isTranscribing = false
    @Published var pttTranscriptionError: String? = nil

    // Transcript preview (inline preview after PTT release or auto-mode send)
    @Published var showTranscriptPreview = false
    @Published var transcriptPreviewText = ""
    @Published var isTranscribingPreview = false

    // Debug
    @Published var showDebug: Bool {
        didSet { UserDefaults.standard.set(showDebug, forKey: "showDebug") }
    }
    @Published var debugHub = DebugHubInfo()
    @Published var debugServices: [DebugService] = []
    @Published var debugSessions: [DebugHubSession] = []
    @Published var debugTmux: [DebugTmuxSession] = []
    @Published var debugLog: [String] = []
    @Published var debugLastUpdated = ""

    // Usage stats
    @Published var usage5hPct: Int?
    @Published var usage7dPct: Int?
    @Published var usage5hReset: String?
    @Published var usage7dReset: String?

    // Computed
    var activeSession: VoiceSession? {
        guard let id = activeSessionId else { return nil }
        return sessions.first { $0.id == id }
    }

    var activeMessages: [ChatMessage] {
        let msgs = activeSession?.messages ?? []
        return msgs.count > 50 ? Array(msgs.suffix(50)) : msgs
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
    private var meteringTimer: Timer?
    private var backgroundRecordingTimer: Timer?
    private let maxLevelSamples = 50
    private var debugRefreshTimer: Timer?
    private var pausedAudioSessionId: String?
    private var suppressNextAutoRecord = false
    private var currentActivity: Activity<VoiceHubActivityAttributes>?
    private var silencePlayer: AVAudioPlayer?
    private var ttsPlayer: AVAudioPlayer?
    private var keepaliveEngine: AVAudioEngine?
    private var playbackVADEngine: AVAudioEngine?
    private var playbackVADProcessor: PlaybackVADProcessor?
    private var lastPingTime: Date?
    private var lastMicActionTime: Date?
    private var pttInterrupted = false
    private var recordingStartedAt: Date?
    private var pingWatchdogTimer: Timer?

    // MARK: - Init

    override init() {
        self.serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        self.autoRecord = UserDefaults.standard.object(forKey: "autoRecord") as? Bool ?? false
        self.vadEnabled = UserDefaults.standard.object(forKey: "vadEnabled") as? Bool ?? true
        self.autoInterrupt = UserDefaults.standard.object(forKey: "autoInterrupt") as? Bool ?? false
        self.vadSilenceDuration =
            UserDefaults.standard.object(forKey: "vadSilenceDuration") as? Double ?? 3.0
        self.vadThreshold =
            UserDefaults.standard.object(forKey: "vadThreshold") as? Double ?? 10.0
        self.allowRecordWhileThinking =
            UserDefaults.standard.object(forKey: "allowRecordWhileThinking") as? Bool ?? true
        self.micMuted = UserDefaults.standard.bool(forKey: "micMuted")
        self.inputMode = UserDefaults.standard.string(forKey: "inputMode") ?? "auto"
        self.backgroundMode =
            UserDefaults.standard.object(forKey: "backgroundMode") as? Bool ?? true
        self.soundThinkingAuto =
            UserDefaults.standard.object(forKey: "soundThinkingAuto") as? Bool ?? true
        self.soundThinkingPTT =
            UserDefaults.standard.object(forKey: "soundThinkingPTT") as? Bool ?? true
        self.soundListeningAuto =
            UserDefaults.standard.object(forKey: "soundListeningAuto") as? Bool ?? true
        self.soundProcessingAuto =
            UserDefaults.standard.object(forKey: "soundProcessingAuto") as? Bool ?? true
        self.soundReadyAuto =
            UserDefaults.standard.object(forKey: "soundReadyAuto") as? Bool ?? true
        self.soundReadyPTT =
            UserDefaults.standard.object(forKey: "soundReadyPTT") as? Bool ?? true
        self.hapticsRecordingAuto =
            UserDefaults.standard.object(forKey: "hapticsRecordingAuto") as? Bool ?? true
        self.hapticsRecordingPTT =
            UserDefaults.standard.object(forKey: "hapticsRecordingPTT") as? Bool ?? true
        self.hapticsPlaybackAuto =
            UserDefaults.standard.object(forKey: "hapticsPlaybackAuto") as? Bool ?? true
        self.hapticsPlaybackPTT =
            UserDefaults.standard.object(forKey: "hapticsPlaybackPTT") as? Bool ?? true
        self.hapticsSend =
            UserDefaults.standard.object(forKey: "hapticsSend") as? Bool ?? true
        self.hapticsSessionAuto =
            UserDefaults.standard.object(forKey: "hapticsSessionAuto") as? Bool ?? true
        self.hapticsSessionPTT =
            UserDefaults.standard.object(forKey: "hapticsSessionPTT") as? Bool ?? true
        self.hapticsSessionTyping =
            UserDefaults.standard.object(forKey: "hapticsSessionTyping") as? Bool ?? true
        self.notifyAuto =
            UserDefaults.standard.object(forKey: "notifyAuto") as? Bool ?? true
        self.notifyPTT =
            UserDefaults.standard.object(forKey: "notifyPTT") as? Bool ?? true
        self.notifyTyping =
            UserDefaults.standard.object(forKey: "notifyTyping") as? Bool ?? true
        self.liveActivityAuto =
            UserDefaults.standard.object(forKey: "liveActivityAuto") as? Bool ?? true
        self.liveActivityPTT =
            UserDefaults.standard.object(forKey: "liveActivityPTT") as? Bool ?? true
        self.showDebug = UserDefaults.standard.bool(forKey: "showDebug")
        self.recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording.wav")
        super.init()

        setupAudioSession()
        observeAppLifecycle()
        endStaleLiveActivities()
        requestNotificationPermission()

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

    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    private func observeAppLifecycle() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Start silence loop if background mode is on and there are sessions
                if self.backgroundMode && !self.sessions.isEmpty {
                    // Request background execution time to ensure silence loop starts
                    self.backgroundTaskID = UIApplication.shared.beginBackgroundTask {
                        UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
                        self.backgroundTaskID = .invalid
                    }
                    self.startSilenceLoop()
                    // End background task after silence is playing
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        if self.backgroundTaskID != .invalid {
                            UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
                            self.backgroundTaskID = .invalid
                        }
                    }
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stopSilenceLoop()
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.endLiveActivity()
            }
        }
        // Handle audio session interruptions (e.g. user opens Spotify)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            // Extract value before Task to avoid Swift 6 data-race warning
            let typeVal = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                guard let self,
                    let typeVal,
                    let kind = AVAudioSession.InterruptionType(rawValue: typeVal)
                else { return }
                switch kind {
                case .began:
                    // Another app took audio focus — pause keepalive
                    self.silencePlayer?.pause()
                case .ended:
                    // Re-activate audio session and restart keepalive
                    if self.backgroundMode && !self.sessions.isEmpty {
                        self.setupAudioSession()
                        if self.appInBackground {
                            // Restart keepalive engine if it died
                            if self.keepaliveEngine?.isRunning != true {
                                self.stopSilenceLoop()
                                self.startSilenceLoop()
                            } else {
                                self.silencePlayer?.play()
                            }
                        }
                    }
                @unknown default:
                    break
                }
            }
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(140))
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func startSilenceLoop() {
        // Ensure audio session is active
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(true)
        } catch {
            print("[audio] Failed to activate session for background: \(error)")
        }

        // Start keepalive engine with input tap (primary keepalive - active audio processing)
        if keepaliveEngine == nil {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let fmt = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { _, _ in
                // Discard audio - just keeps the engine alive
            }
            do {
                try engine.start()
                keepaliveEngine = engine
                print("[audio] Keepalive engine started")
            } catch {
                print("[audio] Keepalive engine failed: \(error)")
            }
        }

        // Start silence player (secondary keepalive)
        guard silencePlayer == nil else { return }
        let sampleRate: Int = 8000
        let numSamples = sampleRate  // 1 second
        var header = Data()
        let dataSize = numSamples * 2
        let fileSize = 36 + dataSize
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46])  // RIFF
        header.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize).littleEndian) { Array($0) })
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45])  // WAVE
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])  // fmt
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // PCM
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // mono
        header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) {
            Array($0)
        })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate * 2).littleEndian) {
            Array($0)
        })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61])  // data
        header.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) {
            Array($0)
        })
        // Near-silent samples (amplitude 1 out of 32767)
        var samples = Data(count: dataSize)
        for i in stride(from: 0, to: dataSize, by: 2) {
            samples[i] = 1
            samples[i + 1] = 0
        }
        header.append(samples)

        do {
            silencePlayer = try AVAudioPlayer(data: header)
            silencePlayer?.numberOfLoops = -1
            silencePlayer?.volume = 0.0
            silencePlayer?.prepareToPlay()
            silencePlayer?.play()
            print("[audio] Silence loop started for background keepalive")
        } catch {
            print("[audio] Silence loop failed: \(error)")
        }
    }

    private func stopSilenceLoop() {
        silencePlayer?.stop()
        silencePlayer = nil
        if let engine = keepaliveEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            keepaliveEngine = nil
            print("[audio] Keepalive engine stopped")
        }
    }

    // MARK: - Helpers

    private func sessionIndex(_ id: String) -> Int? {
        sessions.firstIndex { $0.id == id }
    }

    /// Update status text for a session, and if it's the active session, also update the top-level statusText.
    private func updateStatusText(_ text: String, for sessionId: String) {
        if let idx = sessionIndex(sessionId) {
            sessions[idx].statusText = text
        }
        if sessionId == activeSessionId {
            statusText = text
        }
    }

    private func addMessage(_ sessionId: String, role: String, text: String) {
        guard let idx = sessionIndex(sessionId) else { return }
        sessions[idx].messages.append(ChatMessage(role: role, text: text))
        saveChats()
    }

    // MARK: - Chat Persistence

    private let chatsKey = "voice-hub-chats"

    private func saveChats() {
        var data: [String: [[String: String]]] = [:]
        for session in sessions {
            data[session.id] = session.messages.map { ["role": $0.role, "text": $0.text] }
        }
        if let jsonData = try? JSONSerialization.data(withJSONObject: data) {
            UserDefaults.standard.set(jsonData, forKey: chatsKey)
        }
    }

    private func loadSavedMessages(for sessionId: String) -> [ChatMessage]? {
        guard let jsonData = UserDefaults.standard.data(forKey: chatsKey),
            let data = try? JSONSerialization.jsonObject(with: jsonData)
                as? [String: [[String: String]]],
            let messages = data[sessionId], !messages.isEmpty
        else { return nil }
        return messages.compactMap { dict in
            guard let role = dict["role"], let text = dict["text"] else { return nil }
            return ChatMessage(role: role, text: text)
        }
    }

    private func clearSavedChat(for sessionId: String) {
        guard let jsonData = UserDefaults.standard.data(forKey: chatsKey),
            var data = try? JSONSerialization.jsonObject(with: jsonData)
                as? [String: [[String: String]]]
        else { return }
        data.removeValue(forKey: sessionId)
        if let updated = try? JSONSerialization.data(withJSONObject: data) {
            UserDefaults.standard.set(updated, forKey: chatsKey)
        }
    }

    // MARK: - Server-Side History

    private func fetchHistory(voiceId: String, sessionId: String) {
        guard let baseURL = httpBaseURL() else { return }
        let url = baseURL.appendingPathComponent("api/history/\(voiceId)")
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let messages = json["messages"] as? [[String: Any]]
            else { return }
            Task { @MainActor in
                guard let self, let idx = self.sessionIndex(sessionId) else { return }
                let chatMessages = messages.suffix(50).compactMap { msg -> ChatMessage? in
                    guard let role = msg["role"] as? String,
                        let text = msg["text"] as? String
                    else { return nil }
                    return ChatMessage(role: role, text: text)
                }
                if !chatMessages.isEmpty {
                    // Keep any system messages, prepend history
                    let systemMessages = self.sessions[idx].messages.filter { $0.role == "system" }
                    self.sessions[idx].messages = chatMessages + systemMessages
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

    // MARK: - Ping Watchdog

    private func startPingWatchdog() {
        lastPingTime = Date()
        pingWatchdogTimer?.invalidate()
        pingWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, self.isConnected, let last = self.lastPingTime else { return }
                if Date().timeIntervalSince(last) > 60 {
                    print("[ws] No ping for 60s, reconnecting")
                    self.handleDisconnect()
                }
            }
        }
    }

    // MARK: - Audio Session

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord, mode: .spokenAudio,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .allowBluetoothHFP, .mixWithOthers])
            try session.setPreferredSampleRate(48000)
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)
        } catch {
            print("[audio] Session setup failed: \(error)")
        }
    }

    // MARK: - Audio Cues (background only)

    private var appInBackground: Bool {
        UIApplication.shared.applicationState != .active
    }

    // MARK: - Thinking Sound

    func startThinkingSound() {
        stopThinkingSound()
        guard (isAutoMode && soundThinkingAuto) || (pushToTalk && soundThinkingPTT) else { return }
        thinkingSoundTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, !self.appInBackground else { return }
                self.tonePlayer.thinkingTick()
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
        lastPingTime = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isConnected = false
        isConnecting = false
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
        isConnecting = false
        if isRecording { stopRecording(discard: true) }
        if isPlaying {
            audioPlayer?.stop()
            audioPlayer = nil
            isPlaying = false
            playingSessionId = nil
        }
        isProcessing = false
        suppressNextAutoRecord = false
        clearTranscriptPreview()
        stopPlaybackVAD()
        statusText = "Disconnected"
        pingWatchdogTimer?.invalidate()
        pingWatchdogTimer = nil
        lastPingTime = nil
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
                let liveIds = Set(list.compactMap { $0["session_id"] as? String })
                // Remove any sessions the hub no longer knows about
                for s in sessions where !liveIds.contains(s.id) {
                    removeSession(s.id)
                }
                // Add new sessions
                for s in list {
                    if let sid = s["session_id"] as? String, sessionIndex(sid) == nil {
                        addSessionFromDict(s)
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
                if activeSessionId == nil && !showDebug {
                    switchToSession(sid)
                }
            }

        case "session_terminated":
            if let sid = sessionId {
                removeSession(sid)
            }

        case "session_status":
            if let sid = sessionId, let statusStr = json["status"] as? String,
                let status = SessionStatus(rawValue: statusStr),
                let idx = sessionIndex(sid)
            {
                sessions[idx].status = status
                if status == .ready {
                    addMessage(sid, role: "system", text: "Claude connected.")
                    // Show thinking indicator while waiting for agent's first message
                    sessions[idx].isThinking = true
                    if (isAutoMode && soundReadyAuto) || (pushToTalk && soundReadyPTT) {
                        tonePlayer.cueSessionReady()
                    }
                    if (isAutoMode && hapticsSessionAuto) || (pushToTalk && hapticsSessionPTT)
                        || (typingMode && hapticsSessionTyping)
                    { haptic(.success) }
                }
            }

        case "ping":
            lastPingTime = Date()

        case "error":
            let msg = json["message"] as? String ?? "Unknown error"
            statusText = "Error: \(msg)"

        case "thinking":
            // Hub is about to speak - show thinking indicator
            if let sid = sessionId, let idx = sessionIndex(sid) {
                sessions[idx].isThinking = true
                sessions[idx].awaitingInput = false
                updateStatusText("Thinking...", for: sid)
                if sid == activeSessionId {
                    if !typingMode { startThinkingSound() }
                    updateLiveActivity()
                }
            }

        // Session-scoped messages
        case "assistant_text":
            if let sid = sessionId, let t = json["text"] as? String {
                if let idx = sessionIndex(sid) {
                    sessions[idx].isThinking = false
                    sessions[idx].awaitingInput = true
                    // In voice modes, audio will follow and set "Speaking..."
                    // In typing mode, go straight to ready-ish state
                    if typingMode {
                        updateStatusText("Ready", for: sid)
                    }
                }
                stopThinkingSound()
                addMessage(sid, role: "assistant", text: t)
                if sid == activeSessionId {
                    isProcessing = false
                    updateLiveActivity()
                } else if let idx = sessionIndex(sid) {
                    sessions[idx].unreadCount += 1
                }
                // Notify in background, gated by per-mode toggle
                if appInBackground {
                    let shouldNotify =
                        (isAutoMode && notifyAuto) || (pushToTalk && notifyPTT)
                        || (typingMode && notifyTyping)
                    if shouldNotify {
                        let voiceName =
                            sessions.first(where: { $0.id == sid })?.label ?? "Agent"
                        sendNotification(title: voiceName, body: t)
                    }
                }
            }

        case "user_text":
            if let sid = sessionId, let t = json["text"] as? String {
                addMessage(sid, role: "user", text: t)
                // Clear transcript preview now that hub confirmed the text
                if sid == activeSessionId && showTranscriptPreview {
                    clearTranscriptPreview()
                }
                if let idx = sessionIndex(sid) {
                    sessions[idx].isThinking = true
                    sessions[idx].statusText = "Thinking..."
                }
                if sid == activeSessionId {
                    isProcessing = false
                    if !typingMode { startThinkingSound() }
                    updateLiveActivity()
                }
            }

        case "audio":
            if let sid = sessionId, let b64 = json["data"] as? String,
                let audioData = Data(base64Encoded: b64)
            {
                if let idx = sessionIndex(sid) {
                    sessions[idx].status = .active
                }
                updateStatusText("Speaking...", for: sid)
                if sid == activeSessionId {
                    // Play audio for active session (works in foreground and background)
                    playAudio(sid, data: audioData)
                    updateLiveActivity()
                } else if activeSessionId == nil {
                    // No active session (on home screen) - buffer it
                    if let idx = sessionIndex(sid) {
                        sessions[idx].audioBuffer.append(audioData)
                    }
                } else {
                    // Different session active - buffer it
                    if let idx = sessionIndex(sid) {
                        sessions[idx].audioBuffer.append(audioData)
                    }
                }
            }

        case "listening":
            if let sid = sessionId {
                if let idx = sessionIndex(sid) { sessions[idx].awaitingInput = true }
                // Skip if already recording for this session
                if isRecording, recordingSessionId == sid { break }

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
                    if suppressNextAutoRecord {
                        if let idx = sessionIndex(sid) {
                            sessions[idx].pendingListen = true
                        }
                    } else if typingMode {
                        if let idx = sessionIndex(sid) {
                            sessions[idx].pendingListen = true
                        }
                        updateStatusText("Type a message", for: sid)
                    } else if effectiveAutoRecord || bgAutoRecord {
                        if isPlaying {
                            // Still playing audio - defer until playback finishes
                            if let idx = sessionIndex(sid) {
                                sessions[idx].pendingListen = true
                            }
                        } else {
                            if soundListeningAuto { tonePlayer.cueListening() }
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
                sessions[idx].status = .ready
                let stillProcessing = json["processing"] as? Bool ?? false
                if stillProcessing {
                    // Agent is still processing (e.g. wait_for_response=false)
                    sessions[idx].isThinking = true
                    updateStatusText("Thinking...", for: sid)
                    if sid == activeSessionId {
                        if !typingMode { startThinkingSound() }
                    }
                } else {
                    sessions[idx].isThinking = false
                    stopThinkingSound()
                    // Don't override status if user still needs to respond
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
            // Agent finished a fire-and-forget turn (wait_for_response=False).
            // Do NOT terminate — the hub session is still alive; Claude may return.
            // Just reset processing state so the UI isn't stuck.
            if let sid = sessionId, let idx = sessionIndex(sid) {
                sessions[idx].isThinking = false
                updateStatusText("Ready", for: sid)
                if sid == activeSessionId {
                    isProcessing = false
                    stopThinkingSound()
                    statusText = "Ready"
                    updateLiveActivity()
                }
            }

        case "project_status":
            if let sid = sessionId, let idx = sessionIndex(sid) {
                sessions[idx].project = json["project"] as? String ?? ""
                sessions[idx].projectArea = json["area"] as? String ?? ""
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
        let statusStr = dict["status"] as? String ?? "starting"
        let status = SessionStatus(rawValue: statusStr) ?? .starting
        let tmux = dict["tmux_session"] as? String ?? sid
        let isReady = status == .ready || dict["mcp_connected"] as? Bool == true

        // Restore saved voice/speed preferences
        let savedPrefs = loadSessionPrefs(sid)
        let sessionVoice = savedPrefs?.voice ?? voice
        let sessionSpeed = savedPrefs?.speed ?? 1.0
        let sessionLabel = ALL_VOICES.first { $0.id == sessionVoice }?.name ?? label

        var session = VoiceSession(
            id: sid, label: sessionLabel, voice: sessionVoice, speed: sessionSpeed,
            status: isReady ? .ready : status, tmuxSession: tmux)
        session.project = dict["project"] as? String ?? ""
        session.projectArea = dict["project_area"] as? String ?? ""
        session.unreadCount = dict["unread_count"] as? Int ?? 0

        if isReady {
            session.messages.append(ChatMessage(role: "system", text: "Claude connected."))
        } else {
            session.messages.append(
                ChatMessage(role: "system", text: "Session started. Waiting for Claude..."))
        }

        // Restore thinking state from server
        if dict["processing"] as? Bool == true {
            session.isThinking = true
        }

        sessions.append(session)

        // Fetch message history from server
        fetchHistory(voiceId: voice, sessionId: sid)
    }

    func switchToSession(_ id: String) {
        if activeSessionId != id {
            // Pause audio from previous session (don't stop/interrupt)
            if isPlaying, let player = audioPlayer, player.isPlaying {
                stopPlaybackVAD()
                player.pause()
                pausedAudioSessionId = playingSessionId
                isPlaying = false
            }
            if isRecording { stopRecording(discard: true) }
            stopThinkingSound()
            suppressNextAutoRecord = false
            showPTTTextField = false
            pttPreviewText = ""
            pttTranscriptionError = nil
            clearTranscriptPreview()
        }
        activeSessionId = id
        showDebug = false

        // Clear unread and tell server we're viewing this session
        if let idx = sessionIndex(id), sessions[idx].unreadCount > 0 {
            sessions[idx].unreadCount = 0
        }
        markSessionViewing(id)

        endLiveActivity()
        if !typingMode {
            startLiveActivity(sessionId: id)
        }

        if let session = activeSession {
            statusText = session.statusText.isEmpty
                ? (session.status == .ready ? "Ready" : "Waiting for Claude...")
                : session.statusText

            // Derive processing state from session (don't carry over from previous session)
            isProcessing = session.statusText == "Processing..."

            // Resume thinking sound if session is thinking (not in typing mode)
            if session.isThinking && !typingMode {
                startThinkingSound()
            }

            // Resume paused audio for this session
            if pausedAudioSessionId == id, let player = audioPlayer {
                player.play()
                isPlaying = true
                playingSessionId = id
                pausedAudioSessionId = nil
                statusText = "Speaking..."
            }
            // Play buffered audio received while in background
            else if let idx = sessionIndex(id), !sessions[idx].audioBuffer.isEmpty {
                playBufferedAudio(id)
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
                        if soundListeningAuto { tonePlayer.cueListening() }
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
            withJSONObject: ["voice": voiceId])
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
                // Only auto-switch if still on the home page
                if self.activeSessionId == nil && !self.showDebug {
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

    private func markSessionViewing(_ id: String) {
        guard let baseURL = httpBaseURL() else { return }
        let url = baseURL.appendingPathComponent("api/sessions/\(id)/viewing")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    func playMessageTTS(messageId: UUID, text: String, voice: String?) {
        // Toggle off if already playing this message
        if ttsPlayingMessageId == messageId {
            stopMessageTTS()
            return
        }
        stopMessageTTS()
        ttsPlayingMessageId = messageId
        guard let baseURL = httpBaseURL() else { ttsPlayingMessageId = nil; return }
        let url = baseURL.appendingPathComponent("api/tts")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["text": text, "voice": voice ?? "af_sky"]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request) { [weak self] data, resp, error in
            DispatchQueue.main.async {
                guard let self, self.ttsPlayingMessageId == messageId else { return }
                guard let data, error == nil,
                      let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200 else {
                    self.ttsPlayingMessageId = nil
                    return
                }
                do {
                    let player = try AVAudioPlayer(data: data)
                    self.ttsPlayer = player
                    player.delegate = self
                    player.play()
                } catch {
                    self.ttsPlayingMessageId = nil
                }
            }
        }.resume()
    }

    func stopMessageTTS() {
        ttsPlayer?.stop()
        ttsPlayer = nil
        ttsPlayingMessageId = nil
    }

    private func removeSession(_ id: String) {
        clearSavedChat(for: id)
        clearSessionPrefs(id)
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
        if isPlaying, let player = audioPlayer, player.isPlaying {
            player.pause()
            pausedAudioSessionId = playingSessionId
            isPlaying = false
        }
        if isRecording { stopRecording(discard: true) }
        stopThinkingSound()
        stopPlaybackVAD()
        suppressNextAutoRecord = false
        showPTTTextField = false
        pttPreviewText = ""
        pttTranscriptionError = nil
        clearTranscriptPreview()
        showDebug = false
        activeSessionId = nil
        endLiveActivity()
    }

    private func updateSessionVoice(_ voice: String) {
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

    private func updateSessionSpeed(_ speed: Double) {
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

    // MARK: - Session Preferences Persistence

    private func saveSessionPrefs(_ sessionId: String, voice: String, speed: Double) {
        var prefs = loadAllSessionPrefs()
        prefs[sessionId] = ["voice": voice, "speed": speed]
        if let data = try? JSONSerialization.data(withJSONObject: prefs) {
            UserDefaults.standard.set(data, forKey: "sessionPrefs")
        }
    }

    private func loadSessionPrefs(_ sessionId: String) -> (voice: String, speed: Double)? {
        let prefs = loadAllSessionPrefs()
        guard let p = prefs[sessionId],
            let voice = p["voice"] as? String,
            let speed = p["speed"] as? Double
        else { return nil }
        return (voice, speed)
    }

    private func loadAllSessionPrefs() -> [String: [String: Any]] {
        guard let data = UserDefaults.standard.data(forKey: "sessionPrefs"),
            let prefs = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return [:] }
        return prefs
    }

    private func clearSessionPrefs(_ sessionId: String) {
        var prefs = loadAllSessionPrefs()
        prefs.removeValue(forKey: sessionId)
        if let data = try? JSONSerialization.data(withJSONObject: prefs) {
            UserDefaults.standard.set(data, forKey: "sessionPrefs")
        }
    }

    func httpBaseURL() -> URL? {
        var base = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.hasPrefix("http://") && !base.hasPrefix("https://") {
            base = "https://" + base
        }
        return URL(string: base)
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
            }
        }.resume()
    }

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
    }

    private func formatResetTime(_ isoStr: String) -> String {
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

    // MARK: - Audio Playback

    private func playAudio(_ sessionId: String, data: Data) {
        if (isAutoMode && hapticsPlaybackAuto) || (pushToTalk && hapticsPlaybackPTT) {
            haptic(.soft)
        }
        statusText = "Speaking..."
        isPlaying = true
        playingSessionId = sessionId

        do {
            // Ensure audio session is active (important for background playback)
            try AVAudioSession.sharedInstance().setActive(true)
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = self
            audioPlayer?.play()
            startPlaybackVAD()
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
        stopPlaybackVAD()
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        playingSessionId = nil
        pausedAudioSessionId = nil
        // Clear any remaining buffered audio
        if let idx = sessionIndex(sid) {
            sessions[idx].audioBuffer.removeAll()
            sessions[idx].statusText = "Ready"
        }
        statusText = "Ready"
        sendJSON(["session_id": sid, "type": "playback_done"])
    }

    private func playBufferedAudio(_ sessionId: String) {
        guard let idx = sessionIndex(sessionId), !sessions[idx].audioBuffer.isEmpty else { return }
        let data = sessions[idx].audioBuffer.removeFirst()
        statusText = "Speaking..."
        isPlaying = true
        playingSessionId = sessionId

        do {
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = self
            audioPlayer?.play()
        } catch {
            print("[audio] Buffered playback error: \(error)")
            if let idx2 = sessionIndex(sessionId), !sessions[idx2].audioBuffer.isEmpty {
                playBufferedAudio(sessionId)
            } else {
                isPlaying = false
                playingSessionId = nil
                sendJSON(["session_id": sessionId, "type": "playback_done"])
            }
        }
    }

    // MARK: - Recording

    func startRecording(sessionId: String? = nil) {
        let sid = sessionId ?? activeSessionId
        guard let sid else { return }
        if showTranscriptPreview { clearTranscriptPreview() }
        recordingSessionId = sid

        // Check permission status directly (avoid async request which is unreliable in background)
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            beginRecording()
        case .undetermined:
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    guard let self, granted else {
                        self?.statusText = "Microphone access denied"
                        return
                    }
                    self.beginRecording()
                }
            }
        default:
            statusText = "Microphone access denied"
        }
    }

    private func beginRecording() {
        if (isAutoMode && hapticsRecordingAuto) || (pushToTalk && hapticsRecordingPTT) {
            haptic(.medium)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            // Ensure audio session is active (critical for background recording)
            try AVAudioSession.sharedInstance().setActive(true)
            audioRecorder = try AVAudioRecorder(url: recordingURL, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
            isRecording = true
            recordingStartedAt = Date()
            audioLevels = []
            if let sid = recordingSessionId {
                updateStatusText("Recording...", for: sid)
            } else {
                statusText = "Recording..."
            }
            updateLiveActivity()
            startMetering()

            let isBackground = UIApplication.shared.applicationState != .active
            // Always enable VAD in background (only way to stop recording without UI)
            if effectiveVAD || isBackground {
                startVAD()
            }
            // Safety timeout: auto-stop recording after 30s in background
            if isBackground {
                backgroundRecordingTimer?.invalidate()
                backgroundRecordingTimer = Timer.scheduledTimer(
                    withTimeInterval: 30, repeats: false
                ) { [weak self] _ in
                    Task { @MainActor in
                        if self?.isRecording == true {
                            self?.stopRecording()
                        }
                    }
                }
            }
        } catch {
            print("[mic] Recording error: \(error)")
            statusText = "Recording error"
        }
    }

    /// Stops recording hardware and returns duration + session ID. Does NOT handle send/transcribe logic.
    private func stopRecordingHardware() -> (duration: TimeInterval, sessionId: String?) {
        guard let recorder = audioRecorder, recorder.isRecording else { return (0, nil) }
        recorder.stop()
        audioRecorder = nil
        isRecording = false
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil
        stopMetering()
        stopVAD()
        backgroundRecordingTimer?.invalidate()
        backgroundRecordingTimer = nil
        let sid = recordingSessionId
        return (duration, sid)
    }

    func stopRecording(discard: Bool = false) {
        let (recordingDuration, sid) = stopRecordingHardware()
        guard sid != nil || discard else { return }

        guard !discard, let sid else {
            recordingSessionId = nil
            return
        }

        // PTT preview mode: transcribe locally instead of sending to hub
        if showPTTTextField {
            recordingSessionId = nil
            if recordingDuration < 0.5 {
                print("[ptt-preview] Recording too short (\(recordingDuration)s), skipping transcription")
                pttTranscriptionError = "Recording too short. Hold the mic to record, then swipe right."
                return
            }
            if let audioData = try? Data(contentsOf: recordingURL), audioData.count > 1000 {
                print("[ptt-preview] Recording stopped for preview, \(audioData.count) bytes (\(recordingDuration)s)")
                pttTranscriptionError = nil
                isTranscribing = true
                statusText = "Transcribing..."
                transcribeAudio(audioData)
            } else {
                print("[ptt-preview] No audio data at recording URL")
                pttTranscriptionError = "No audio recorded. Hold the mic to record, then swipe right."
            }
            return
        }

        if (isAutoMode && hapticsRecordingAuto) || (pushToTalk && hapticsRecordingPTT) {
            haptic(.light)
        }
        if soundProcessingAuto && isAutoMode { tonePlayer.cueProcessing() }
        isProcessing = true
        updateStatusText("Processing...", for: sid)
        updateLiveActivity()

        if let audioData = try? Data(contentsOf: recordingURL) {
            let b64 = audioData.base64EncodedString()
            // Check if agent is awaiting input or busy
            let isAwaiting = sessionIndex(sid).flatMap { sessions[$0].awaitingInput } ?? false
            if isAwaiting {
                sendJSON(["session_id": sid, "type": "audio", "data": b64])
            } else {
                // Agent is busy — send as audio interjection
                sendJSON(["session_id": sid, "type": "interjection", "data": b64])
            }
            // Fire parallel transcription for user feedback (both auto and PTT swipe-up)
            if audioData.count > 1000 {
                transcriptPreviewText = ""
                isTranscribingPreview = true
                showTranscriptPreview = true
                transcribeForPreview(audioData)
            }
        } else {
            statusText = "Error reading audio"
            isProcessing = false
            // Send empty audio so hub doesn't hang
            sendJSON(["session_id": sid, "type": "audio", "data": ""])
        }
        recordingSessionId = nil
    }

    func cancelRecording() {
        guard isRecording, let sid = recordingSessionId else { return }
        stopRecording(discard: true)
        // Suppress next auto-record so cancel doesn't immediately re-trigger
        suppressNextAutoRecord = true
        // Send empty audio so hub doesn't hang
        sendJSON(["session_id": sid, "type": "audio", "data": ""])
        statusText = "Recording cancelled"
    }

    func sendText() {
        let text = typingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let sid = activeSessionId else { return }
        if hapticsSend && typingMode { haptic(.medium) }
        typingText = ""
        // Check if agent is awaiting input or busy
        let isAwaiting = sessionIndex(sid).flatMap { sessions[$0].awaitingInput } ?? false
        if isAwaiting {
            // Normal text input
            if let idx = sessionIndex(sid) { sessions[idx].pendingListen = false }
            sendJSON(["session_id": sid, "type": "text", "text": text])
        } else {
            // Agent is busy — send as interjection
            sendJSON(["session_id": sid, "type": "interjection", "text": text])
        }
    }

    // MARK: - PTT Preview (swipe right to type/transcribe)

    private func transcribeAudio(_ audioData: Data) {
        guard let baseURL = httpBaseURL() else {
            print("[ptt-preview] No base URL, aborting transcription")
            isTranscribing = false
            pttTranscriptionError = "Cannot connect to server"
            return
        }

        print("[ptt-preview] Sending \(audioData.count) bytes to transcribe")
        let url = baseURL.appendingPathComponent("api/transcribe")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = audioData
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }
                self.isTranscribing = false
                self.statusText = ""
                if let error {
                    print("[ptt-preview] Transcription error: \(error)")
                    self.pttTranscriptionError = "Transcription failed. Type your message instead."
                    return
                }
                let httpCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard let data,
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    print("[ptt-preview] Invalid response (\(httpCode))")
                    self.pttTranscriptionError = "Transcription failed. Type your message instead."
                    return
                }
                // Check for server error
                if let serverError = json["error"] as? String {
                    print("[ptt-preview] Server error (\(httpCode)): \(serverError)")
                    self.pttTranscriptionError = "Transcription error: \(serverError)"
                    return
                }
                if let text = json["text"] as? String, !text.isEmpty {
                    print("[ptt-preview] Got transcription (\(httpCode)): \(text)")
                    self.pttPreviewText = text
                    self.pttTranscriptionError = nil
                } else {
                    print("[ptt-preview] Empty text (\(httpCode))")
                    self.pttTranscriptionError = "No speech detected. Tap the mic to try again."
                }
            }
        }.resume()
    }

    /// Parallel transcription for inline preview display (used by both PTT release and auto-mode send).
    private func transcribeForPreview(_ audioData: Data) {
        guard let baseURL = httpBaseURL() else {
            isTranscribingPreview = false
            pttTranscriptionError = "Cannot connect to server"
            return
        }

        let url = baseURL.appendingPathComponent("api/transcribe")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = audioData
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            Task { @MainActor in
                guard let self else { return }
                self.isTranscribingPreview = false
                if error != nil {
                    self.pttTranscriptionError = "Transcription failed"
                    return
                }
                guard let data,
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let text = json["text"] as? String, !text.isEmpty
                else {
                    self.pttTranscriptionError = "No speech detected"
                    return
                }
                if let serverError = json["error"] as? String {
                    self.pttTranscriptionError = "Transcription error: \(serverError)"
                    return
                }
                self.transcriptPreviewText = text
                self.pttTranscriptionError = nil
            }
        }.resume()
    }

    func sendPreviewText() {
        let text = pttPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let sid = activeSessionId else {
            dismissPTTTextField()
            return
        }
        if hapticsSend { haptic(.medium) }
        let isAwaiting = sessionIndex(sid).flatMap { sessions[$0].awaitingInput } ?? false
        if isAwaiting {
            if let idx = sessionIndex(sid) { sessions[idx].pendingListen = false }
            sendJSON(["session_id": sid, "type": "text", "text": text])
        } else {
            sendJSON(["session_id": sid, "type": "interjection", "text": text])
        }
        pttPreviewText = ""
        pttTranscriptionError = nil
        showPTTTextField = false
    }

    func dismissPTTTextField() {
        if isRecording { stopRecording(discard: true) }
        isTranscribing = false
        showPTTTextField = false
        // If there's text, return to transcript preview instead of fully dismissing
        let text = pttPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            transcriptPreviewText = text
            showTranscriptPreview = true
        }
        pttPreviewText = ""
        pttTranscriptionError = nil
    }

    // Mic button action: context-dependent (debounced to prevent double-taps)
    func micAction() {
        let now = Date()
        if let last = lastMicActionTime, now.timeIntervalSince(last) < 0.4 { return }
        lastMicActionTime = now

        if isPlaying {
            interruptPlayback()
        } else if isRecording {
            stopRecording()
        } else if micMuted {
            return
        } else if let sid = activeSessionId {
            // User manually tapped mic - clear cancel suppress and pending listen
            suppressNextAutoRecord = false
            if let idx = sessionIndex(sid), sessions[idx].pendingListen {
                sessions[idx].pendingListen = false
            }
            startRecording(sessionId: sid)
        }
    }

    // MARK: - Push to Talk

    func pttPressed() {
        if showTranscriptPreview { clearTranscriptPreview() }
        if isPlaying {
            interruptPlayback()
            pttInterrupted = true
            return
        }
        // Don't record on the same press that interrupted playback
        if pttInterrupted { return }
        // Don't re-trigger if already recording
        if isRecording { return }
        if isProcessing || micMuted || recordBlockedByThinking { return }
        if let sid = activeSessionId {
            suppressNextAutoRecord = false
            if let idx = sessionIndex(sid), sessions[idx].pendingListen {
                sessions[idx].pendingListen = false
            }
            startRecording(sessionId: sid)
        }
    }

    func pttReleased() {
        pttInterrupted = false
        if isRecording {
            stopRecording()
        }
    }

    /// Called on swipe-up: sends audio to hub immediately. Parallel transcription fires via stopRecording's normal path.
    func pttSwipeUpSend() {
        guard isRecording else { return }
        pttInterrupted = false
        stopRecording()  // normal path: sends audio to hub + fires parallel transcription
    }

    /// Called on normal release (no swipe): stops recording, transcribes for preview. Audio NOT sent to hub.
    func pttReleasedForPreview() {
        pttInterrupted = false
        let (duration, _) = stopRecordingHardware()
        guard duration > 0 else {
            recordingSessionId = nil
            return
        }

        if duration < 0.3 {
            // Too short, just go back to idle
            recordingSessionId = nil
            return
        }

        if let audioData = try? Data(contentsOf: recordingURL), audioData.count > 1000 {
            transcriptPreviewText = ""
            isTranscribingPreview = true
            showTranscriptPreview = true
            pttTranscriptionError = nil
            recordingSessionId = nil
            transcribeForPreview(audioData)
        } else {
            recordingSessionId = nil
        }
    }

    /// Called when user swipes right on mic button in PTT mode.
    /// If recording is active, stops and transcribes. Otherwise shows empty text field for typing.
    func enterPTTTextMode() {
        pttTranscriptionError = nil
        pttInterrupted = false
        showPTTTextField = true
        if isRecording {
            stopRecording()  // triggers transcription via showPTTTextField branch
        }
    }

    /// Taps inline transcript preview to open keyboard for editing.
    func tapTranscriptToEdit() {
        showTranscriptPreview = false
        pttPreviewText = transcriptPreviewText
        showPTTTextField = true
    }

    /// Sends the inline transcript preview text directly.
    func sendTranscriptPreview() {
        let text = transcriptPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let sid = activeSessionId else {
            clearTranscriptPreview()
            return
        }
        if hapticsSend { haptic(.medium) }
        if let idx = sessionIndex(sid) { sessions[idx].pendingListen = false }
        sendJSON(["session_id": sid, "type": "text", "text": text])
        clearTranscriptPreview()
    }

    func clearTranscriptPreview() {
        showTranscriptPreview = false
        transcriptPreviewText = ""
        isTranscribingPreview = false
        pttTranscriptionError = nil
    }

    // MARK: - VAD (Voice Activity Detection)

    private var vadAudioEngine: AVAudioEngine?
    private var vadProcessor: VADProcessor?

    private func startVAD() {
        stopVAD()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        let threshold = Float(vadThreshold)
        let duration = vadSilenceDuration
        let processor = VADProcessor(
            silenceThreshold: threshold,
            silenceDuration: duration
        ) { [weak self] in
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

    // MARK: - Playback VAD (Auto Interrupt)

    private func startPlaybackVAD() {
        guard effectiveAutoInterrupt, !micMuted else { return }
        stopPlaybackVAD()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        let processor = PlaybackVADProcessor { [weak self] in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.stopPlaybackVAD()
                self.interruptPlayback()
                if let sid = self.activeSessionId {
                    self.startRecording(sessionId: sid)
                }
            }
        }
        playbackVADProcessor = processor

        installPlaybackVADTap(on: input, format: format, processor: processor)

        do {
            try engine.start()
            playbackVADEngine = engine
        } catch {
            print("[playback-vad] Engine start failed: \(error)")
        }
    }

    private func stopPlaybackVAD() {
        playbackVADEngine?.inputNode.removeTap(onBus: 0)
        playbackVADEngine?.stop()
        playbackVADEngine = nil
        playbackVADProcessor = nil
    }

    // MARK: - Mic Mute

    private func handleMuteActivated() {
        // Stop any active recording
        if isRecording {
            stopRecording(discard: true)
            if let sid = recordingSessionId ?? activeSessionId {
                sendJSON(["session_id": sid, "type": "audio", "data": ""])
            }
        }
        // Send silent audio for any sessions with pending listen
        for i in sessions.indices where sessions[i].pendingListen {
            sendJSON(["session_id": sessions[i].id, "type": "audio", "data": ""])
            sessions[i].pendingListen = false
        }
        updateStatusText("Muted", for: activeSessionId ?? "")
        stopPlaybackVAD()
    }

    // MARK: - Audio Metering

    private func startMetering() {
        stopMetering()
        meteringTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.audioRecorder, recorder.isRecording else {
                    return
                }
                recorder.updateMeters()
                // averagePower is in dB (-160 to 0), normalize to 0...1
                let db = recorder.averagePower(forChannel: 0)
                let normalized = max(0, min(1, CGFloat((db + 50) / 50)))
                self.audioLevels.append(normalized)
                if self.audioLevels.count > self.maxLevelSamples {
                    self.audioLevels.removeFirst(self.audioLevels.count - self.maxLevelSamples)
                }
            }
        }
    }

    private func stopMetering() {
        meteringTimer?.invalidate()
        meteringTimer = nil
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

    // MARK: - Live Activity

    private func startLiveActivity(sessionId: String) {
        guard (isAutoMode && liveActivityAuto) || (pushToTalk && liveActivityPTT) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return }

        let attributes = VoiceHubActivityAttributes(sessionId: sessionId)
        let state = VoiceHubActivityAttributes.ContentState(
            voiceName: session.label,
            status: voiceHubStatus(for: session),
            lastMessage: session.messages.last(where: { $0.role == "assistant" })?
                .text.prefix(80).description ?? "",
            inputMode: inputMode
        )

        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            print("[liveactivity] Failed to start: \(error)")
        }
    }

    private func updateLiveActivity() {
        guard let activity = currentActivity,
            let sessionId = activeSessionId,
            let session = sessions.first(where: { $0.id == sessionId })
        else { return }

        let state = VoiceHubActivityAttributes.ContentState(
            voiceName: session.label,
            status: voiceHubStatus(for: session),
            lastMessage: session.messages.last(where: { $0.role == "assistant" })?
                .text.prefix(80).description ?? "",
            inputMode: inputMode
        )

        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    private func endLiveActivity() {
        guard let activity = currentActivity else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        currentActivity = nil
    }

    private func endStaleLiveActivities() {
        // Clean up any activities left over from a previous launch (e.g. force-kill)
        Task {
            for activity in Activity<VoiceHubActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private func voiceHubStatus(for session: VoiceSession) -> VoiceHubStatus {
        if session.isThinking { return .thinking }
        let st = session.statusText
        if st == "Speaking..." || st == "Playing..." { return .speaking }
        if st == "Recording..." || st == "Tap Record" || session.pendingListen { return .listening }
        return .ready
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

extension VoiceHubViewModel: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor in
            self.isConnected = true
            self.isConnecting = false
            self.statusText = "Connected"
            self.startPingWatchdog()
            self.receiveMessage()
            self.fetchSettings()
            self.fetchUsage()
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

extension VoiceHubViewModel: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer, successfully flag: Bool
    ) {
        Task { @MainActor in
            // Handle TTS message playback finishing
            if self.ttsPlayer != nil && self.playingSessionId == nil {
                self.ttsPlayer = nil
                self.ttsPlayingMessageId = nil
                return
            }

            let sid = self.playingSessionId ?? ""

            // Check for more buffered audio to play
            if !sid.isEmpty, let idx = self.sessionIndex(sid),
                !self.sessions[idx].audioBuffer.isEmpty
            {
                self.playBufferedAudio(sid)
                return
            }

            self.stopPlaybackVAD()
            self.isPlaying = false
            self.playingSessionId = nil
            if !sid.isEmpty {
                self.sendJSON(["session_id": sid, "type": "playback_done"])
            }
            self.updateLiveActivity()

            // Handle deferred listen: listening arrived while audio was playing
            if !sid.isEmpty, let idx = self.sessionIndex(sid),
                self.sessions[idx].pendingListen, sid == self.activeSessionId
            {
                let isBackground = UIApplication.shared.applicationState != .active
                let bgAutoRecord = isBackground && self.backgroundMode && self.isAutoMode
                if !self.micMuted && (self.effectiveAutoRecord || bgAutoRecord) {
                    self.sessions[idx].pendingListen = false
                    if self.soundListeningAuto { self.tonePlayer.cueListening() }
                    self.startRecording(sessionId: sid)
                }
            }
            // Background safety net: hub sends "listening" after playback_done,
            // so pendingListen may not be set yet. Schedule a delayed re-check.
            else if !sid.isEmpty, sid == self.activeSessionId,
                UIApplication.shared.applicationState != .active,
                self.backgroundMode, self.isAutoMode, !self.micMuted
            {
                let capturedSid = sid
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self,
                        let idx = self.sessionIndex(capturedSid),
                        self.sessions[idx].pendingListen,
                        !self.isRecording, !self.isPlaying,
                        capturedSid == self.activeSessionId,
                        UIApplication.shared.applicationState != .active
                    else { return }
                    self.sessions[idx].pendingListen = false
                    self.suppressNextAutoRecord = false
                    if self.soundListeningAuto { self.tonePlayer.cueListening() }
                    self.startRecording(sessionId: capturedSid)
                }
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
