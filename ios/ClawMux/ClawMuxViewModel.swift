import ActivityKit
import AVFoundation
import Foundation
import UIKit
import UserNotifications

// MARK: - Models

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: String  // "user", "assistant", "system", "agent"
    let text: String
    var timestamp: Date = Date()
    var msgId: String? = nil    // server-assigned msg_id (for dedup + TTS replay)
    var parentId: String? = nil // parent msg_id for threading
    var isBareAck: Bool = false // thumbs-up ack — no display text
}

/// Canonical agent state matching the backend AgentState enum.
enum AgentState: String {
    case starting, idle, thinking, processing, compacting, dead

    /// True when the agent is busy and not waiting for user input.
    var isWorking: Bool { self == .thinking || self == .processing || self == .compacting }
    /// True when the agent is ready to receive user input.
    var isIdle: Bool { self == .idle }

    var displayLabel: String {
        switch self {
        case .starting: return "Starting..."
        case .idle: return "Ready"
        case .thinking: return "Thinking..."
        case .processing: return "Working..."
        case .compacting: return "Compacting..."
        case .dead: return "Offline"
        }
    }
}

struct VoiceSession: Identifiable {
    let id: String
    var label: String
    var voice: String
    var speed: Double
    var state: AgentState = .starting
    var messages: [ChatMessage] = []
    var tmuxSession: String = ""
    var pendingListen: Bool = false
    var statusText: String = ""
    var audioBuffer: [Data] = []
    var project: String = ""
    var projectArea: String = ""
    var role: String = ""
    var task: String = ""
    var model: String = ""
    var effort: String = ""
    var activity: String = ""
    var toolName: String = ""
    var unreadCount: Int = 0
    var isSpeaking: Bool = false  // audio actively playing — mirrors web 'speaking' sidebar state

    // Derived helpers
    var isThinking: Bool { state == .thinking || state == .processing || state == .compacting }
    var awaitingInput: Bool { state == .idle }
    var isReady: Bool { state == .idle || state == .thinking || state == .processing || state == .compacting }
    var isDead: Bool { state == .dead }
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

    // Ascending two-tone: your turn to speak (2s cooldown matches web)
    private var lastCueTime: Date = .distantPast
    func cueListening() {
        let now = Date()
        guard now.timeIntervalSince(lastCueTime) >= 2.0 else { return }
        lastCueTime = now
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
    let state: String
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
final class ClawMuxViewModel: NSObject, ObservableObject {

    // Connection
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var showSettings = false
    @Published var showNotes = false
    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }

    // Sessions
    @Published var sessions: [VoiceSession] = []
    @Published var currentProject: String = "default"
    @Published var activeSessionId: String? {
        didSet { UserDefaults.standard.set(activeSessionId, forKey: "activeSessionId") }
    }
    @Published var spawningVoiceIds: Set<String> = []
    @Published var errorMessage: String?
    @Published var ttsPlayingMessageId: UUID?

    // Active session UI state
    @Published var statusText = ""
    @Published var isRecording = false
    @Published var isPlaying = false {
        didSet {
            // Keep session.isSpeaking in sync so ringColor uses canonical state, not statusText strings
            let sid = playingSessionId
            if let sid, let idx = sessionIndex(sid) {
                sessions[idx].isSpeaking = isPlaying
            } else if !isPlaying {
                // Playback stopped — clear isSpeaking on any session that had it set
                for i in sessions.indices where sessions[i].isSpeaking {
                    sessions[i].isSpeaking = false
                }
            }
        }
    }
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
    @Published var voiceResponses: Bool = true
    @Published var silentStartup: Bool {
        didSet {
            UserDefaults.standard.set(silentStartup, forKey: "silentStartup")
            updateSetting("silent_startup", value: silentStartup)
        }
    }
    @Published var showAgentMessages: Bool {
        didSet {
            UserDefaults.standard.set(showAgentMessages, forKey: "showAgentMessages")
            updateSetting("show_agent_messages", value: showAgentMessages)
        }
    }
    @Published var verboseMode: Bool {
        didSet { UserDefaults.standard.set(verboseMode, forKey: "verboseMode") }
    }
    @Published var defaultModel: String {
        didSet {
            UserDefaults.standard.set(defaultModel, forKey: "defaultModel")
            updateSetting("default_model", value: defaultModel)
        }
    }
    @Published var defaultEffort: String {
        didSet {
            UserDefaults.standard.set(defaultEffort, forKey: "defaultEffort")
            updateSetting("default_effort", value: defaultEffort)
        }
    }
    @Published var ttsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(ttsEnabled, forKey: "ttsEnabled")
            updateSetting("tts_enabled", value: ttsEnabled)
        }
    }
    @Published var ttsURL: String {
        didSet { UserDefaults.standard.set(ttsURL, forKey: "ttsURL") }
    }
    @Published var sttEnabled: Bool {
        didSet {
            UserDefaults.standard.set(sttEnabled, forKey: "sttEnabled")
            updateSetting("stt_enabled", value: sttEnabled)
        }
    }
    @Published var sttURL: String {
        didSet { UserDefaults.standard.set(sttURL, forKey: "sttURL") }
    }
    @Published var whisperModel: String {
        didSet {
            UserDefaults.standard.set(whisperModel, forKey: "whisperModel")
            updateSetting("whisper_model", value: whisperModel)
        }
    }
    @Published var chatFontSize: Int {
        didSet { UserDefaults.standard.set(chatFontSize, forKey: "chatFontSize") }
    }

    // Global master toggles
    @Published var globalHaptics: Bool {
        didSet { UserDefaults.standard.set(globalHaptics, forKey: "globalHaptics") }
    }
    @Published var globalSounds: Bool {
        didSet { UserDefaults.standard.set(globalSounds, forKey: "globalSounds") }
    }
    @Published var globalNotifications: Bool {
        didSet { UserDefaults.standard.set(globalNotifications, forKey: "globalNotifications") }
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
    @Published var contextPct: Int?

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

    // Stash audio recorded while WS was disconnected — flushed as interjection on reconnect
    private var pendingAudioSend: (sessionId: String, data: Data, isInterjection: Bool)?

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
    private var currentActivity: Activity<ClawMuxActivityAttributes>?
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
    private var reconnectAttempt = 0
    private var backgroundListenWork: DispatchWorkItem?

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
        self.globalHaptics =
            UserDefaults.standard.object(forKey: "globalHaptics") as? Bool ?? true
        self.globalSounds =
            UserDefaults.standard.object(forKey: "globalSounds") as? Bool ?? true
        self.globalNotifications =
            UserDefaults.standard.object(forKey: "globalNotifications") as? Bool ?? true
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
        self.showDebug        = UserDefaults.standard.bool(forKey: "showDebug")
        self.verboseMode      = UserDefaults.standard.object(forKey: "verboseMode")      as? Bool ?? false
        self.silentStartup    = UserDefaults.standard.object(forKey: "silentStartup")    as? Bool ?? false
        self.showAgentMessages = UserDefaults.standard.object(forKey: "showAgentMessages") as? Bool ?? true
        self.ttsEnabled       = UserDefaults.standard.object(forKey: "ttsEnabled")       as? Bool ?? true
        self.ttsURL           = UserDefaults.standard.string(forKey: "ttsURL")           ?? ""
        self.sttEnabled       = UserDefaults.standard.object(forKey: "sttEnabled")       as? Bool ?? true
        self.sttURL           = UserDefaults.standard.string(forKey: "sttURL")           ?? ""
        self.whisperModel     = UserDefaults.standard.string(forKey: "whisperModel")     ?? "high"
        self.defaultModel     = UserDefaults.standard.string(forKey: "defaultModel")     ?? "opus"
        self.defaultEffort    = UserDefaults.standard.string(forKey: "defaultEffort")    ?? "medium"
        self.chatFontSize     = UserDefaults.standard.object(forKey: "chatFontSize")     as? Int  ?? 14
        self.recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording.wav")
        super.init()

        // One-time migration: remove stale UserDefaults chat cache (server API is source of truth)
        UserDefaults.standard.removeObject(forKey: "voice-hub-chats")

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
                guard let self else { return }
                self.stopSilenceLoop()
                // Reconnect if WebSocket dropped while in background (preserve backoff state)
                if !self.isConnected && !self.isConnecting && !self.serverURL.isEmpty {
                    self.connectInternal()
                }
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
                    // Another app took audio focus — stop recording/TTS, pause keepalive
                    if self.isRecording { self.stopRecording(discard: false) }
                    if self.isPlaying {
                        let sid = self.playingSessionId
                        self.stopPlaybackVAD()
                        self.audioPlayer?.stop(); self.audioPlayer = nil
                        self.isPlaying = false; self.playingSessionId = nil
                        // Notify server so session isn't left waiting for playback_done
                        if let sid { self.sendJSON(["session_id": sid, "type": "playback_done"]) }
                    }
                    self.stopMessageTTS()
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
        // Handle route changes (AirPods disconnect, headphones unplugged, etc.)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let reasonVal = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                guard let self,
                    let reasonVal,
                    let reason = AVAudioSession.RouteChangeReason(rawValue: reasonVal)
                else { return }
                switch reason {
                case .oldDeviceUnavailable:
                    // Output device removed — stop playback so it doesn't redirect unexpectedly
                    if self.isPlaying {
                        let sid = self.playingSessionId
                        self.stopPlaybackVAD()
                        self.audioPlayer?.stop(); self.audioPlayer = nil
                        self.isPlaying = false; self.playingSessionId = nil
                        if let sid { self.sendJSON(["session_id": sid, "type": "playback_done"]) }
                    }
                    // Restart keepalive engine if it died on route change
                    if self.backgroundMode && self.appInBackground {
                        if self.keepaliveEngine?.isRunning != true {
                            self.stopSilenceLoop()
                            self.startSilenceLoop()
                        }
                    }
                default:
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

    private func addMessage(_ sessionId: String, role: String, text: String, ts: Double? = nil, msgId: String? = nil) {
        guard let idx = sessionIndex(sessionId) else { return }
        // Deduplicate by server message ID
        if let msgId, sessions[idx].messages.contains(where: { $0.msgId == msgId }) { return }
        var msg = ChatMessage(role: role, text: text)
        if let ts { msg.timestamp = Date(timeIntervalSince1970: ts) }
        msg.msgId = msgId
        sessions[idx].messages.append(msg)
    }

    // MARK: - Server-Side History

    private func fetchHistory(voiceId: String, sessionId: String, initialState: AgentState? = nil) {
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
                    var m = ChatMessage(role: role, text: text)
                    if let ts = msg["ts"] as? Double { m.timestamp = Date(timeIntervalSince1970: ts) }
                    if let mid = msg["id"] as? String { m.msgId = mid }
                    if let pid = msg["parent_id"] as? String { m.parentId = pid }
                    if msg["bare_ack"] as? Bool == true { m.isBareAck = true }
                    return m
                }
                if !chatMessages.isEmpty {
                    self.sessions[idx].messages = Array(chatMessages)
                } else if let state = initialState {
                    // No history yet — show appropriate placeholder (mirrors web addSession)
                    let isReady = state != .starting && state != .dead
                    let placeholder = isReady ? "Claude connected." : "Session started. Waiting for Claude..."
                    self.sessions[idx].messages = [ChatMessage(role: "system", text: placeholder)]
                }
            }
        }.resume()
    }

    // Cursor-based reconnect sync — appends only messages after the last known ID.
    // Falls back to full fetchHistory if no cursor is available (empty history).
    // Mirrors web _reconnectSyncSession.
    private func reconnectSyncHistory(voiceId: String, sessionId: String) {
        guard let idx = sessionIndex(sessionId) else { return }

        // Find last message with a server-assigned ID (cursor)
        let cursor = sessions[idx].messages.reversed().first(where: { $0.msgId != nil })?.msgId

        if cursor == nil && sessions[idx].messages.isEmpty {
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
                        let i = self.sessionIndex(sessionId),
                        self.sessions[i].messages.contains(where: { $0.msgId == msgId })
                    { continue } // skip duplicates
                    if let i = self.sessionIndex(sessionId) {
                        self.sessions[i].messages.append(m)
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
            // No .mixWithOthers — voice assistant needs exclusive mic focus during recording.
            // .mixWithOthers allows other app audio to bleed into the mic, corrupting VAD
            // energy levels and triggering false speech detection.
            try session.setCategory(
                .playAndRecord, mode: .spokenAudio,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .allowBluetoothHFP])
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
        guard globalSounds, (isAutoMode && soundThinkingAuto) || (pushToTalk && soundThinkingPTT) else { return }
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

    /// Public connect — resets backoff (use for user-initiated connects).
    func connect() {
        reconnectAttempt = 0
        connectInternal()
    }

    /// Internal connect — does NOT reset backoff (used by scheduleReconnect).
    private func connectInternal() {
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
        // Exponential backoff: 2s, 4s, 8s, 16s, capped at 30s
        let delay = min(30.0, 2.0 * pow(2.0, Double(reconnectAttempt)))
        reconnectAttempt += 1
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.connectInternal() }
        }
        reconnectWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
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
        guard isConnected || isConnecting else { return }  // debounce duplicate calls
        isConnected = false
        isConnecting = false
        if isRecording { stopRecording(discard: true) }
        recordingSessionId = nil
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
        stopMessageTTS()
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
        webSocketTask?.send(.string(string)) { [weak self] error in
            if let error {
                print("[ws] Send error: \(error)")
                Task { @MainActor in self?.handleDisconnect() }
            }
        }
    }

    /// Replay audio stashed during a connection drop — sent as interjection so the hub
    /// transcribes and queues it correctly (mirrors web _flushPendingAudio called on WS open).
    private func flushPendingAudio() {
        guard let pending = pendingAudioSend, isConnected else { return }
        pendingAudioSend = nil
        let b64 = pending.data.base64EncodedString()
        let type = pending.isInterjection ? "interjection" : "audio"
        print("[audio] Flushing stashed audio as \(type) for session \(pending.sessionId)")
        sendJSON(["session_id": pending.sessionId, "type": "interjection", "data": b64])
        updateStatusText("Transcribing…", for: pending.sessionId)
    }

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

    func sendInterrupt() {
        guard let sid = activeSessionId else { return }
        sendJSON(["session_id": sid, "type": "interrupt"])
    }

    func sendEffort(_ effort: String) {
        guard let sid = activeSessionId else { return }
        sendJSON(["session_id": sid, "type": "set_effort", "effort": effort])
        if let idx = sessionIndex(sid) { sessions[idx].effort = effort }
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
                // Add new sessions; re-sync state and history for existing ones (reconnect)
                for s in list {
                    if let sid = s["session_id"] as? String {
                        if sessionIndex(sid) == nil {
                            addSessionFromDict(s)
                        } else if let idx = sessionIndex(sid) {
                            // Re-sync server-authoritative state (mirrors web session_list reconnect sync)
                            let stateStr = s["state"] as? String ?? ""
                            if let newState = AgentState(rawValue: stateStr) {
                                sessions[idx].state = newState
                            }
                            if let activity = s["activity"] as? String { sessions[idx].activity = activity }
                            if let speed = s["speed"] as? Double { sessions[idx].speed = speed }
                            if let model = s["model"] as? String, !model.isEmpty { sessions[idx].model = model }
                            if let effort = s["effort"] as? String, !effort.isEmpty { sessions[idx].effort = effort }
                            if let project = s["project"] as? String { sessions[idx].project = project }
                            if let area = s["project_area"] as? String { sessions[idx].projectArea = area }
                            if let unread = s["unread_count"] as? Int { sessions[idx].unreadCount = unread }
                            // Cursor-based reconnect sync — appends missed messages (mirrors web _reconnectSyncSession)
                            if let voice = s["voice"] as? String {
                                reconnectSyncHistory(voiceId: voice, sessionId: sid)
                            }
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
                if activeSessionId == nil && !showDebug {
                    switchToSession(sid)
                }
            }

        case "session_terminated":
            if let sid = sessionId {
                removeSession(sid)
            }

        case "project_deleted":
            // Sessions in the deleted project arrive via session_terminated; no extra cleanup needed.
            // currentProject will be updated by a following project_switched event if needed.
            break

        case "project_renamed":
            // Sessions store the project slug, which is unchanged on rename; no action needed.
            break

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

                // First time becoming idle from starting = session just connected
                if prevState == .starting && newState != .starting && newState != .dead {
                    if verboseMode { addMessage(sid, role: "system", text: "Claude connected.") }
                    if globalSounds, (isAutoMode && soundReadyAuto) || (pushToTalk && soundReadyPTT) {
                        tonePlayer.cueSessionReady()
                    }
                    if (isAutoMode && hapticsSessionAuto) || (pushToTalk && hapticsSessionPTT)
                        || (typingMode && hapticsSessionTyping)
                    { haptic(.success) }
                }

                if sid == activeSessionId {
                    updateStatusText(newState.displayLabel, for: sid)
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
            statusText = "Error: \(msg)"

        case "thinking":
            // Legacy event — map to thinking state
            if let sid = sessionId, let idx = sessionIndex(sid) {
                sessions[idx].state = .thinking
                updateStatusText("Thinking...", for: sid)
                if sid == activeSessionId {
                    if !typingMode { startThinkingSound() }
                    updateLiveActivity()
                }
            }

        // Session-scoped messages
        case "assistant_text":
            if let sid = sessionId, let t = json["text"] as? String {
                let fireAndForget = json["fire_and_forget"] as? Bool ?? false
                stopThinkingSound()
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
            if let sid = sessionId, let msg = json["message"] as? [String: Any] {
                let content = msg["content"] as? String ?? ""
                let senderName = (msg["sender_name"] as? String ?? msg["sender"] as? String ?? "?")
                let recipName = (msg["recipient_name"] as? String ?? msg["recipient"] as? String ?? "?")
                let sName = senderName.prefix(1).uppercased() + senderName.dropFirst()
                let rName = recipName.prefix(1).uppercased() + recipName.dropFirst()
                let isBareAck = (msg["bare_ack"] as? Bool ?? false) || ((msg["parent_id"] != nil) && content.isEmpty)
                if isBareAck { break }  // bare acks have no text to display without threading UI
                // Determine direction: if this session is the sender, show "to"; otherwise "from"
                let senderSession = msg["sender"] as? String
                let direction = senderSession == sid ? "to \(rName)" : "from \(sName)"
                let text = "[Agent msg \(direction)] \(content)"
                addMessage(sid, role: "system", text: text, ts: json["ts"] as? Double, msgId: msg["id"] as? String)
                if sid != activeSessionId, let idx = sessionIndex(sid) {
                    sessions[idx].unreadCount += 1
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
                if let idx = sessionIndex(sid) {
                    sessions[idx].messages.append(ack)
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
                if let idx = sessionIndex(sid) {
                    sessions[idx].audioBuffer.append(audioData)
                }
                if sid == activeSessionId {
                    if !isPlaying { _drainAudioBuffer(sid) }
                    updateLiveActivity()
                }
            }

        case "listening":
            if let sid = sessionId {
                if let idx = sessionIndex(sid) { sessions[idx].state = .idle }
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
                        // Defer if audio is playing OR buffered — mirrors web pendingListenAfterPlayback
                        let audioActive = isPlaying
                            || (sessionIndex(sid).map { !sessions[$0].audioBuffer.isEmpty } ?? false)
                        if audioActive {
                            if let idx = sessionIndex(sid) {
                                sessions[idx].pendingListen = true
                            }
                        } else {
                            if globalSounds && soundListeningAuto { tonePlayer.cueListening() }
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
                let audioStillActive = (isPlaying && playingSessionId == sid)
                    || !sessions[idx].audioBuffer.isEmpty
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
        session.model = dict["model"] as? String ?? ""
        session.effort = dict["effort"] as? String ?? ""
        session.activity = dict["activity"] as? String ?? ""
        session.toolName = dict["tool_name"] as? String ?? ""
        session.unreadCount = dict["unread_count"] as? Int ?? 0

        sessions.append(session)

        // Fetch message history from server; add a placeholder only if history comes back empty
        fetchHistory(voiceId: voice, sessionId: sid, initialState: agentState)
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
            pttInterrupted = false
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
            statusText = session.statusText.isEmpty ? session.state.displayLabel : session.statusText

            // Derive processing state from session (don't carry over from previous session)
            isProcessing = session.state.isWorking

            // Resume thinking sound if session is busy (not in typing mode)
            if session.isThinking && !typingMode {
                startThinkingSound()
            }

            // Resume paused audio for this session
            if pausedAudioSessionId == id, let player = audioPlayer {
                if player.play() {
                    isPlaying = true
                    playingSessionId = id
                    statusText = "Speaking..."
                } else {
                    audioPlayer = nil
                }
                pausedAudioSessionId = nil
            }
            // Play buffered audio received while in background
            else if let idx = sessionIndex(id), !sessions[idx].audioBuffer.isEmpty {
                _drainAudioBuffer(id)
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
                        if globalSounds && soundListeningAuto { tonePlayer.cueListening() }
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

    // Derived project list from live sessions (matches web project-selector options)
    var knownProjects: [String] {
        Array(Set(sessions.map(\.project).filter { !$0.isEmpty })).sorted()
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
        let sessionSpeed = activeSessionId.flatMap { sessionIndex($0) }.map { sessions[$0].speed } ?? 1.0
        let body: [String: Any] = ["text": text, "voice": voice ?? "af_sky", "speed": sessionSpeed]
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
                    if !player.play() {
                        self.ttsPlayer = nil
                        self.ttsPlayingMessageId = nil
                    }
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
        // Clean up paused audio held for this session
        if pausedAudioSessionId == id || playingSessionId == id {
            stopPlaybackVAD()
            audioPlayer?.stop()
            audioPlayer = nil
            isPlaying = false
            playingSessionId = nil
            pausedAudioSessionId = nil
        }
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
                if let voiceResp = json["voice_responses"] as? Bool {
                    self.voiceResponses = voiceResp
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
        // Stop any message TTS replay to prevent delegate confusion
        stopMessageTTS()
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
            let started = audioPlayer?.play() ?? false
            if started {
                startPlaybackVAD()
            } else {
                // play() returned false — audio session issue; notify server and reset
                print("[audio] play() returned false for session \(sessionId)")
                audioPlayer = nil
                isPlaying = false
                playingSessionId = nil
                sendJSON(["session_id": sessionId, "type": "playback_done"])
            }
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

    /// Pops the next chunk from the session's audioBuffer and starts playback.
    /// Matches web _playNextQueued — never called while isPlaying is true.
    private func _drainAudioBuffer(_ sessionId: String) {
        guard let idx = sessionIndex(sessionId),
              !sessions[idx].audioBuffer.isEmpty else { return }
        let data = sessions[idx].audioBuffer.removeFirst()
        playAudio(sessionId, data: data)
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
        if globalSounds && soundProcessingAuto && isAutoMode { tonePlayer.cueProcessing() }
        isProcessing = true
        updateStatusText("Processing...", for: sid)
        updateLiveActivity()

        if let audioData = try? Data(contentsOf: recordingURL) {
            let b64 = audioData.base64EncodedString()
            // Check if agent is awaiting input or busy
            let isAwaiting = sessionIndex(sid).flatMap { sessions[$0].awaitingInput } ?? false
            let isInterjection = !isAwaiting
            if !isConnected {
                // WS disconnected — stash audio for replay on reconnect (matches web _pendingAudioSend)
                pendingAudioSend = (sessionId: sid, data: audioData, isInterjection: isInterjection)
                statusText = "Reconnecting — audio saved…"
            } else if isInterjection {
                sendJSON(["session_id": sid, "type": "interjection", "data": b64])
            } else {
                sendJSON(["session_id": sid, "type": "audio", "data": b64])
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
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    self.pttTranscriptionError = "No speech detected"
                    return
                }
                // Check server error before text (matches transcribeAudio ordering)
                if let serverError = json["error"] as? String {
                    self.pttTranscriptionError = "Transcription error: \(serverError)"
                    return
                }
                guard let text = json["text"] as? String, !text.isEmpty else {
                    self.pttTranscriptionError = "No speech detected"
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
        // Capture sessionId before stopRecording clears it
        if isRecording {
            let sid = recordingSessionId ?? activeSessionId
            stopRecording(discard: true)
            if let sid {
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

        let attributes = ClawMuxActivityAttributes(sessionId: sessionId)
        let state = ClawMuxActivityAttributes.ContentState(
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

        let state = ClawMuxActivityAttributes.ContentState(
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
            for activity in Activity<ClawMuxActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private func voiceHubStatus(for session: VoiceSession) -> ClawMuxStatus {
        let st = session.statusText
        if st == "Speaking..." || st == "Playing..." { return .speaking }
        if st == "Recording..." || st == "Tap Record" || session.pendingListen { return .listening }
        switch session.state {
        case .thinking, .processing, .compacting: return .thinking
        case .idle: return .ready
        default: return .ready
        }
    }

    // MARK: - Haptics

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard globalHaptics else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    private func haptic(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard globalHaptics else { return }
        UINotificationFeedbackGenerator().notificationOccurred(type)
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
            self.isConnected = true
            self.isConnecting = false
            self.reconnectAttempt = 0   // reset backoff on successful connection
            self.statusText = "Connected"
            self.setupAudioSession()
            self.startPingWatchdog()
            self.receiveMessage()
            self.fetchSettings()
            self.fetchUsage()
            self.flushPendingAudio()  // replay audio recorded during disconnect
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

extension ClawMuxViewModel: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer, successfully flag: Bool
    ) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor in
            // Use identity comparison — not heuristic state — to identify which player finished
            if let tts = self.ttsPlayer, ObjectIdentifier(tts) == playerID {
                self.ttsPlayer = nil
                self.ttsPlayingMessageId = nil
                return
            }

            let sid = self.playingSessionId ?? ""

            self.stopPlaybackVAD()
            self.isPlaying = false  // clear isPlaying before playingSessionId — isSpeaking didSet depends on order

            // Drain next chunk before sending playback_done (matches web _playNextQueued behavior:
            // only send playback_done when the per-session queue is fully empty)
            if !sid.isEmpty, let idx = self.sessionIndex(sid),
                !self.sessions[idx].audioBuffer.isEmpty
            {
                self._drainAudioBuffer(sid)
                return
            }

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
                    if self.globalSounds && self.soundListeningAuto { self.tonePlayer.cueListening() }
                    self.startRecording(sessionId: sid)
                }
            }
            // Background safety net: hub sends "listening" after playback_done,
            // so pendingListen may not be set yet. Schedule a cancellable delayed re-check.
            else if !sid.isEmpty, sid == self.activeSessionId,
                UIApplication.shared.applicationState != .active,
                self.backgroundMode, self.isAutoMode, !self.micMuted
            {
                let capturedSid = sid
                self.backgroundListenWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    Task { @MainActor in
                        guard let self,
                            let idx = self.sessionIndex(capturedSid),
                            self.sessions[idx].pendingListen,
                            !self.isRecording, !self.isPlaying,
                            capturedSid == self.activeSessionId,
                            UIApplication.shared.applicationState != .active
                        else { return }
                        self.sessions[idx].pendingListen = false
                        self.suppressNextAutoRecord = false
                        if self.globalSounds && self.soundListeningAuto { self.tonePlayer.cueListening() }
                        self.startRecording(sessionId: capturedSid)
                    }
                }
                self.backgroundListenWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(
        _ player: AVAudioPlayer, error: (any Error)?
    ) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor in
            // TTS message decode error — just clear state
            if let tts = self.ttsPlayer, ObjectIdentifier(tts) == playerID {
                self.ttsPlayer = nil
                self.ttsPlayingMessageId = nil
                return
            }
            let sid = self.playingSessionId ?? ""
            self.stopPlaybackVAD()
            self.isPlaying = false
            self.playingSessionId = nil
            self.statusText = "Audio decode error"
            // Drain stale buffer so it doesn't play on next session switch
            if !sid.isEmpty, let idx = self.sessionIndex(sid) {
                self.sessions[idx].audioBuffer.removeAll()
            }
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
