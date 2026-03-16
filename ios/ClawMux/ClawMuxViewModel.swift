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

struct GroupChatMessage: Identifiable, Equatable {
    let id: String      // server-assigned message id
    let role: String    // "user", "assistant", "system"
    let text: String
    let sender: String  // voice id of sender
    let ts: Double      // unix timestamp
    var parentId: String? = nil
    var isBareAck: Bool = false
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
    var tmuxSession: String = ""
    var pendingListen: Bool = false
    var statusText: String = ""
    var project: String = ""
    var projectArea: String = ""
    var role: String = ""
    var task: String = ""
    var projectRepo: String = ""
    var model: String = ""
    var effort: String = ""
    var backend: String = ""     // "claude-code", "opencode", "gemini", "codex"
    var modelId: String = ""     // actual model string, e.g. "claude-opus-4-6", "gpt-5"
    var activity: String = ""
    var toolName: String = ""
    var unreadCount: Int = 0
    var isSpeaking: Bool = false  // audio actively playing — mirrors web 'speaking' sidebar state
    var groupId: String = ""      // non-empty when this session is in a group chat
    var hasOlderMessages: Bool = false  // true when server may have messages older than current history
    var walkingMode: Bool = false  // agent responds in plain spoken text — no markdown

    // Derived helpers
    var isThinking: Bool { state == .thinking || state == .processing || state == .compacting }
    var awaitingInput: Bool { state == .idle }
    var isReady: Bool { state == .idle || state == .thinking || state == .processing || state == .compacting }
    var isDead: Bool { state == .dead }
}

struct ProjectFolder: Identifiable {
    var id: String      // slug
    var name: String
    var voices: [String] // voice IDs
}

struct VoiceInfo: Identifiable {
    let id: String
    let name: String
    let project: String  // static group — overridden at runtime by active session project
}

let ALL_VOICES: [VoiceInfo] = [
    // Default group
    VoiceInfo(id: "af_sky",     name: "Sky",     project: "Default"),
    VoiceInfo(id: "af_alloy",   name: "Alloy",   project: "Default"),
    VoiceInfo(id: "af_nova",    name: "Nova",     project: "Default"),
    VoiceInfo(id: "af_sarah",   name: "Sarah",   project: "Default"),
    VoiceInfo(id: "am_adam",    name: "Adam",    project: "Default"),
    VoiceInfo(id: "am_echo",    name: "Echo",    project: "Default"),
    VoiceInfo(id: "am_eric",    name: "Eric",    project: "Default"),
    VoiceInfo(id: "am_onyx",    name: "Onyx",    project: "Default"),
    VoiceInfo(id: "bm_fable",   name: "Fable",   project: "Default"),
    // Personal group
    VoiceInfo(id: "af_bella",   name: "Bella",   project: "Personal"),
    VoiceInfo(id: "af_jessica", name: "Jessica", project: "Personal"),
    VoiceInfo(id: "af_heart",   name: "Heart",   project: "Personal"),
    VoiceInfo(id: "am_michael", name: "Michael", project: "Personal"),
    VoiceInfo(id: "am_liam",    name: "Liam",    project: "Personal"),
    VoiceInfo(id: "am_fenrir",  name: "Fenrir",  project: "Personal"),
    VoiceInfo(id: "bf_emma",    name: "Emma",    project: "Personal"),
    VoiceInfo(id: "bm_george",  name: "George",  project: "Personal"),
    VoiceInfo(id: "bm_daniel",  name: "Daniel",  project: "Personal"),
    // Extended group
    VoiceInfo(id: "af_aoede",   name: "Aoede",   project: "Extended"),
    VoiceInfo(id: "af_jadzia",  name: "Jadzia",  project: "Extended"),
    VoiceInfo(id: "af_kore",    name: "Kore",    project: "Extended"),
    VoiceInfo(id: "af_nicole",  name: "Nicole",  project: "Extended"),
    VoiceInfo(id: "af_river",   name: "River",   project: "Extended"),
    VoiceInfo(id: "am_puck",    name: "Puck",    project: "Extended"),
    VoiceInfo(id: "bf_alice",   name: "Alice",   project: "Extended"),
    VoiceInfo(id: "bf_lily",    name: "Lily",    project: "Extended"),
    VoiceInfo(id: "bm_lewis",   name: "Lewis",   project: "Extended"),
]

/// O(1) name→id lookup — avoids O(n) linear scan on ALL_VOICES per message in group history parsing.
let VOICE_NAME_TO_ID: [String: String] = Dictionary(
    uniqueKeysWithValues: ALL_VOICES.map { ($0.name.lowercased(), $0.id) }
)

/// O(1) id→name lookup — used by GroupChatView bubble sender labels.
let VOICE_ID_TO_NAME: [String: String] = Dictionary(
    uniqueKeysWithValues: ALL_VOICES.map { ($0.id, $0.name) }
)

let SPEED_OPTIONS: [(label: String, value: Double)] = [
    ("0.75x", 0.75), ("1x", 1.0), ("1.25x", 1.25), ("1.5x", 1.5), ("2x", 2.0),
]

// MARK: - Debug Data Models

struct DebugHubInfo {
    var port = 0
    var uptimeSeconds = 0
    var browserConnected = false
    var clientCount = 0
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
    let project: String
    let projectRepo: String
    let workDir: String
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

struct DebugSystemInfo {
    var cpuPercent: Double? = nil
    var ramUsedGB: Double = 0
    var ramTotalGB: Double = 0
    var ramPercent: Double = 0
    var gpuPercent: Int? = nil
    var vramUsedMB: Int = 0
    var vramTotalMB: Int = 0
    var gpuTempC: Int? = nil
}

// MARK: - ViewModel

@MainActor
final class ClawMuxViewModel: NSObject, ObservableObject {

    // Connection
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var showSettings = false
    @Published var showNotes = false
    @Published var walkingModeActive = false
    @Published var pendingNotificationSessionId: String? = nil
    @Published var isFocusMode = false
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
    @Published var knownGroupChats: [(name: String, voices: [String])] = []
    @Published var activeGroupName: String? = nil  // non-nil when viewing a group chat
    @Published var groupMessages: [GroupChatMessage] = []
    @Published var folders: [ProjectFolder] = []  // fetched from GET /api/projects on connect
    var groupIdToName: [String: String] = [:]  // "gc-xxx" → "group name" for disband API

    func groupName(for groupId: String) -> String? { groupIdToName[groupId] }
    func groupId(for name: String) -> String? { groupIdToName.first(where: { $0.value == name })?.key }
    @Published var errorMessage: String?
    @Published var ttsPlayingMessageId: UUID?

    // Active session UI state
    @Published var statusText = ""
    @Published var isRecording = false
    @Published var isPlaying = false {
        didSet {
            // Keep session.isSpeaking in sync so ringColor uses canonical state, not statusText strings
            let sid = audio.currentPlayingSessionId
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
    @Published var isPlaybackPaused = false  // user-triggered transport pause
    @Published var isProcessing = false
    @Published var audioLevels: [CGFloat] = []
    let spectrumSource = SpectrumBandSource()   // isolated — updates don't trigger full VM re-renders
    @Published var messagesBySession: [String: [ChatMessage]] = [:]
    @Published var audioBufferBySession: [String: [Data]] = [:]

    // Controls
    // Input mode: "auto", "ptt", "typing"
    @Published var inputMode: String {
        didSet {
            UserDefaults.standard.set(inputMode, forKey: "inputMode")
            if let sid = activeSessionId {
                sendJSON(["session_id": sid, "type": "set_mode", "mode": inputMode == "typing" ? "text" : "voice"])
            }
            // Cancel in-flight recording when switching away from voice modes
            if isRecording && inputMode == "typing" { audio.cancelRecording() }
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
        didSet { UserDefaults.standard.set(autoRecord, forKey: "autoRecord"); updateSetting("auto_record", value: autoRecord) }
    }
    @Published var vadEnabled: Bool {
        didSet { UserDefaults.standard.set(vadEnabled, forKey: "vadEnabled"); updateSetting("auto_end", value: vadEnabled) }
    }
    @Published var autoInterrupt: Bool {
        didSet { UserDefaults.standard.set(autoInterrupt, forKey: "autoInterrupt"); updateSetting("auto_interrupt", value: autoInterrupt) }
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
            if micMuted { audio.handleMuteActivated() }
        }
    }
    @Published var backgroundMode: Bool {
        didSet {
            UserDefaults.standard.set(backgroundMode, forKey: "backgroundMode")
            if backgroundMode { liveActivityEnabled = true }
        }
    }
    @Published var voiceResponses: Bool = true {
        didSet { updateSetting("voice_responses", value: voiceResponses) }
    }
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
        didSet {
            UserDefaults.standard.set(ttsURL, forKey: "ttsURL")
            updateSetting("tts_url", value: ttsURL)
        }
    }
    @Published var sttEnabled: Bool {
        didSet {
            UserDefaults.standard.set(sttEnabled, forKey: "sttEnabled")
            updateSetting("stt_enabled", value: sttEnabled)
            // STT off → force text-only mode (no voice input without transcription)
            if !sttEnabled { inputMode = "typing" }
        }
    }
    @Published var sttURL: String {
        didSet {
            UserDefaults.standard.set(sttURL, forKey: "sttURL")
            updateSetting("stt_url", value: sttURL)
        }
    }
    @Published var whisperModel: String {
        didSet {
            UserDefaults.standard.set(whisperModel, forKey: "whisperModel")
            updateSetting("quality_mode", value: whisperModel)  // server key is quality_mode
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
        didSet {
            UserDefaults.standard.set(globalSounds, forKey: "globalSounds")
            if !globalSounds { audio.stopToneEngine() }
        }
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
    @Published var liveActivityEnabled: Bool {
        didSet {
            UserDefaults.standard.set(liveActivityEnabled, forKey: "liveActivityEnabled")
            if !liveActivityEnabled { endLiveActivity() }
        }
    }
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
    @Published var debugSystem = DebugSystemInfo()
    @Published var debugStatus = ""
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
        return messagesBySession[activeSessionId ?? ""] ?? []
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
    var pendingAudioSend: (sessionId: String, data: Data, isInterjection: Bool)?

    // Audio subsystem — owns all audio I/O, recording, playback, VAD, metering
    private(set) lazy var audio: AudioManager = AudioManager(vm: self)

    // PushToTalk framework — Action Button hold-to-talk in walking mode
    private(set) lazy var pttManager: PushToTalkManager = {
        let m = PushToTalkManager()
        m.vm = self
        return m
    }()

    // Private
    var webSocketTask: URLSessionWebSocketTask?
    var urlSession: URLSession?
    var reconnectWork: DispatchWorkItem?
    var debugRefreshTimer: Timer?
    var usageRefreshTimer: Timer?
    var currentActivity: Activity<ClawMuxActivityAttributes>?
    var lastPingTime: Date?
    var pingWatchdogTimer: Timer?
    var reconnectAttempt = 0

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
        self.liveActivityEnabled =
            UserDefaults.standard.object(forKey: "liveActivityEnabled") as? Bool ?? true
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
        super.init()

        // Enforce: STT off at launch → stay in typing mode regardless of stored inputMode
        if !sttEnabled { inputMode = "typing" }

        // One-time migration: remove stale UserDefaults chat cache (server API is source of truth)
        UserDefaults.standard.removeObject(forKey: "voice-hub-chats")

        audio.setupAudioSession()
        pttManager.setup()
        observeAppLifecycle()
        endStaleLiveActivities()
        requestNotificationPermission()

        if !serverURL.isEmpty {
            connect()
        }
        // If serverURL is empty, the welcome screen's Settings button handles first-run setup
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
                    self.backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
                        guard let self else { return }
                        UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
                        self.backgroundTaskID = .invalid
                    }
                    self.audio.startSilenceLoop()
                    // End background task after silence is playing
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        guard let self else { return }
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
                self.audio.stopSilenceLoop()
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
        // Handle notification tap → switch to agent session
        NotificationCenter.default.addObserver(
            forName: .switchToSession, object: nil, queue: .main
        ) { [weak self] notification in
            let sid = notification.userInfo?["sessionId"] as? String
            Task { @MainActor in
                guard let self, let sid else { return }
                self.switchToSession(sid)
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
                    if self.isRecording { self.audio.stopRecording(discard: false) }
                    if self.isPlaying {
                        let sid = self.audio.currentPlayingSessionId
                        self.audio.stopPlaybackVAD()
                        self.isPlaying = false
                        // Notify server so session isn't left waiting for playback_done
                        if let sid { self.sendJSON(["session_id": sid, "type": "playback_done"]) }
                    }
                    self.audio.stopMessageTTS()
                    self.audio.pauseSilencePlayer()
                case .ended:
                    // Re-activate audio session and restart keepalive
                    if self.backgroundMode && !self.sessions.isEmpty {
                        self.audio.setupAudioSession()
                        if self.audio.appInBackground {
                            // Restart keepalive engine if it died
                            if !self.audio.keepaliveEngineIsRunning {
                                self.audio.stopSilenceLoop()
                                self.audio.startSilenceLoop()
                            } else {
                                self.audio.resumeSilencePlayer()
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
                    // Output device removed — fully stop playback (player + VAD + buffer + playback_done)
                    if self.isPlaying || self.isPlaybackPaused {
                        self.audio.interruptPlayback()
                    }
                    // Restart keepalive engine if it died on route change
                    if self.backgroundMode && self.audio.appInBackground {
                        if !self.audio.keepaliveEngineIsRunning {
                            self.audio.stopSilenceLoop()
                            self.audio.startSilenceLoop()
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

    // Helpers, Server-Side History → ClawMuxViewModel+Sessions.swift


    // Ping Watchdog, WebSocket, Hub Protocol → ClawMuxViewModel+WebSocket.swift

    // MARK: - URL Helpers

    func httpBaseURL() -> URL? {
        var base = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasPrefix("wss://") {
            base = "https://" + base.dropFirst(6)
        } else if base.hasPrefix("ws://") {
            base = "http://" + base.dropFirst(5)
        } else if !base.hasPrefix("http://") && !base.hasPrefix("https://") {
            base = "https://" + base
        }
        // Strip /ws suffix or trailing slash — serverURL may include these but HTTP base should not
        if base.hasSuffix("/ws") { base = String(base.dropLast(3)) }
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        return URL(string: base)
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
