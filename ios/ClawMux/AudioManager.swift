import AVFoundation
import UIKit

// MARK: - AudioManager
// Handles all audio I/O: recording, playback, silence keepalive, VAD, metering,
// thinking sounds, PTT preview transcription, and push-to-talk logic.
//
// Architecture: AudioManager is @MainActor and holds a weak reference to the ViewModel.
// All @Published state (isRecording, isPlaying, audioLevels, etc.) stays on the ViewModel
// so SwiftUI can observe it unchanged. AudioManager mutates that state via vm?.xxx = ...
// The ViewModel owns one instance: private let audio: AudioManager.

@MainActor
final class AudioManager: NSObject {

    weak var vm: ClawMuxViewModel?

    // MARK: - Private Audio State

    private var audioPlayer: AVAudioPlayer?
    private var audioRecorder: AVAudioRecorder?
    private let recordingURL: URL
    private var playingSessionId: String?
    private var recordingSessionId: String?
    private lazy var tonePlayer = TonePlayer()
    private var thinkingSoundTimer: Timer?
    private var meteringTimer: Timer?
    private var prevMeterLevel: CGFloat = 0
    private var backgroundRecordingTimer: Timer?
    private let maxLevelSamples = 100
    private var pausedAudioSessionId: String?
    private var suppressNextAutoRecord = false
    private var silencePlayer: AVAudioPlayer?
    private var ttsPlayer: AVAudioPlayer?
    private var keepaliveEngine: AVAudioEngine?
    private var playbackVADEngine: AVAudioEngine?
    private var playbackVADProcessor: PlaybackVADProcessor?
    private var lastMicActionTime: Date?
    private var pttInterrupted = false
    private var recordingStartedAt: Date?
    private var backgroundListenWork: DispatchWorkItem?
    private var vadAudioEngine: AVAudioEngine?
    private var vadProcessor: VADProcessor?
    private var spectrumEngine: AVAudioEngine?
    private var spectrumProcessor: SpectrumProcessor?

    // MARK: - Init

    init(vm: ClawMuxViewModel) {
        self.vm = vm
        self.recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording.wav")
        super.init()
    }

    // MARK: - Accessors (used by ViewModel and AVAudioPlayerDelegate)

    var currentPlayingSessionId: String? { playingSessionId }
    var currentRecordingSessionId: String? { recordingSessionId }
    var currentSuppressNextAutoRecord: Bool {
        get { suppressNextAutoRecord }
        set { suppressNextAutoRecord = newValue }
    }

    // MARK: - Audio Session

    func setupAudioSession() {
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
            // Do NOT activate here — activate on demand before recording/playback to allow idle deactivation
        } catch {
            print("[audio] Session setup failed: \(error)")
        }
    }

    /// Deactivates the audio session when neither recording nor playing, freeing the mic hardware.
    /// Called after recording/playback ends. Reactivation happens automatically before the next use.
    private func deactivateIfIdle() {
        guard vm?.isRecording != true, vm?.isPlaying != true,
              keepaliveEngine == nil, silencePlayer == nil else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Non-fatal — session may already be inactive
        }
    }

    // MARK: - Audio Cues (background only)

    var appInBackground: Bool {
        UIApplication.shared.applicationState != .active
    }

    // MARK: - Tone Cues

    func cueSessionReady() { tonePlayer.cueSessionReady() }
    func cueListening()    { tonePlayer.cueListening() }

    // MARK: - Thinking Sound

    func startThinkingSound() {
        stopThinkingSound()
        guard let vm else { return }
        guard vm.globalSounds,
              (vm.isAutoMode && vm.soundThinkingAuto) || (vm.pushToTalk && vm.soundThinkingPTT)
        else { return }
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

    // MARK: - Background Silence Loop (keepalive for background audio)

    func startSilenceLoop() {
        // Ensure audio session is active
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(true)
        } catch {
            print("[audio] Failed to activate session for background: \(error)")
        }

        // Start keepalive engine with input tap (primary keepalive - active audio processing)
        // Simulator has no real microphone — skip the input tap to avoid crash/double-tap errors
        #if !targetEnvironment(simulator)
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
                input.removeTap(onBus: 0)  // clean up tap so next call can try again
                print("[audio] Keepalive engine failed: \(error)")
            }
        }
        #endif

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

    func stopSilenceLoop() {
        silencePlayer?.stop()
        silencePlayer = nil
        if let engine = keepaliveEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            keepaliveEngine = nil
            print("[audio] Keepalive engine stopped")
        }
    }

    func pauseSilencePlayer() {
        silencePlayer?.pause()
    }

    func resumeSilencePlayer() {
        silencePlayer?.play()
    }

    var keepaliveEngineIsRunning: Bool {
        keepaliveEngine?.isRunning == true
    }

    // MARK: - Session Switch Helpers

    /// Pauses currently playing audio for a session switch (doesn't interrupt).
    /// Returns the session ID that was paused, or nil if nothing was playing.
    @discardableResult
    func pauseCurrentPlaybackForSessionSwitch() -> String? {
        guard let vm, vm.isPlaying, let player = audioPlayer, player.isPlaying else { return nil }
        stopPlaybackVAD()
        player.pause()
        let sid = playingSessionId
        pausedAudioSessionId = sid
        vm.isPlaying = false
        return sid
    }

    /// Resume paused audio for a specific session after switching back to it.
    /// Returns true if audio resumed successfully.
    @discardableResult
    func resumePlaybackForSession(_ sessionId: String) -> Bool {
        guard pausedAudioSessionId == sessionId, let player = audioPlayer else { return false }
        if player.play() {
            vm?.isPlaying = true
            playingSessionId = sessionId
            vm?.statusText = "Speaking..."
            pausedAudioSessionId = nil
            return true
        }
        audioPlayer = nil
        pausedAudioSessionId = nil
        return false
    }

    /// Clear PTT and recording state for a session switch.
    func clearSessionSwitchState() {
        pttInterrupted = false
        suppressNextAutoRecord = false
    }

    /// Clean up audio state when a session is removed.
    func cleanupSession(_ sessionId: String) {
        guard let vm else { return }
        if pausedAudioSessionId == sessionId || playingSessionId == sessionId {
            stopPlaybackVAD()
            audioPlayer?.stop()
            audioPlayer = nil
            vm.isPlaying = false
            playingSessionId = nil
            pausedAudioSessionId = nil
        }
    }

    var hasPausedAudioForSession: String? { pausedAudioSessionId }

    // MARK: - Audio Playback

    func playAudio(_ sessionId: String, data: Data) {
        guard let vm else { return }
        // Stop any message TTS replay to prevent delegate confusion
        stopMessageTTS()
        if (vm.isAutoMode && vm.hapticsPlaybackAuto) || (vm.pushToTalk && vm.hapticsPlaybackPTT) {
            vm.haptic(.soft)
        }
        vm.statusText = "Speaking..."
        vm.isPlaying = true
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
                vm.isPlaying = false
                playingSessionId = nil
                vm.sendJSON(["session_id": sessionId, "type": "playback_done"])
            }
        } catch {
            print("[audio] Playback error: \(error)")
            vm.statusText = "Audio error"
            vm.isPlaying = false
            vm.sendJSON(["session_id": sessionId, "type": "playback_done"])
        }
    }

    func pausePlayback() {
        guard let vm, vm.isPlaying, let player = audioPlayer else { return }
        player.pause()
        vm.isPlaying = false
        vm.isPlaybackPaused = true
    }

    func resumePlayback() {
        guard let vm else { return }
        guard vm.isPlaybackPaused, let player = audioPlayer else {
            vm.isPlaybackPaused = false
            return
        }
        if player.play() {
            vm.isPlaybackPaused = false
            vm.isPlaying = true
        } else {
            vm.isPlaybackPaused = false
        }
    }

    func interruptPlayback() {
        guard let vm else { return }
        guard vm.isPlaying || vm.isPlaybackPaused, let sid = playingSessionId else { return }
        suppressNextAutoRecord = true  // prevent playback_done → listening → auto-record
        stopPlaybackVAD()
        audioPlayer?.stop()
        audioPlayer = nil
        vm.isPlaying = false
        vm.isPlaybackPaused = false
        playingSessionId = nil
        pausedAudioSessionId = nil
        // Clear any remaining buffered audio
        if let idx = vm.sessionIndex(sid) {
            vm.sessions[idx].audioBuffer.removeAll()
            vm.sessions[idx].statusText = "Ready"
        }
        vm.statusText = "Ready"
        vm.sendJSON(["session_id": sid, "type": "playback_done"])
    }

    /// Pops the next chunk from the session's audioBuffer and starts playback.
    /// Matches web _playNextQueued — never called while isPlaying is true.
    func drainAudioBuffer(_ sessionId: String) {
        guard let vm,
              let idx = vm.sessionIndex(sessionId),
              !vm.sessions[idx].audioBuffer.isEmpty else { return }
        let data = vm.sessions[idx].audioBuffer.removeFirst()
        playAudio(sessionId, data: data)
    }

    // MARK: - Message TTS (replay from chat)

    func playMessageTTS(messageId: UUID, text: String, voice: String?) {
        guard let vm else { return }
        // Toggle off if already playing this message
        if vm.ttsPlayingMessageId == messageId {
            stopMessageTTS()
            return
        }
        stopMessageTTS()
        vm.ttsPlayingMessageId = messageId
        guard let baseURL = vm.httpBaseURL() else { vm.ttsPlayingMessageId = nil; return }
        let url = baseURL.appendingPathComponent("api/tts")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let sessionSpeed = vm.activeSessionId
            .flatMap { vm.sessionIndex($0) }
            .map { vm.sessions[$0].speed } ?? 1.0
        let body: [String: Any] = ["text": text, "voice": voice ?? "af_sky", "speed": sessionSpeed]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request) { [weak self] data, resp, error in
            Task { @MainActor [weak self] in
                guard let self, let vm = self.vm,
                      vm.ttsPlayingMessageId == messageId else { return }
                guard let data, error == nil,
                      let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200 else {
                    vm.ttsPlayingMessageId = nil
                    return
                }
                do {
                    let player = try AVAudioPlayer(data: data)
                    self.ttsPlayer = player
                    player.delegate = self
                    if !player.play() {
                        self.ttsPlayer = nil
                        vm.ttsPlayingMessageId = nil
                    }
                } catch {
                    vm.ttsPlayingMessageId = nil
                }
            }
        }.resume()
    }

    func stopMessageTTS() {
        ttsPlayer?.stop()
        ttsPlayer = nil
        vm?.ttsPlayingMessageId = nil
    }

    // MARK: - Recording

    func startRecording(sessionId: String? = nil) {
        guard let vm else { return }
        let sid = sessionId ?? vm.activeSessionId
        guard let sid else { return }
        if vm.showTranscriptPreview { vm.clearTranscriptPreview() }
        recordingSessionId = sid

        // Check permission status directly (avoid async request which is unreliable in background)
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            beginRecording()
        case .undetermined:
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    guard let self, granted else {
                        self?.vm?.statusText = "Microphone access denied"
                        return
                    }
                    self.beginRecording()
                }
            }
        default:
            vm.statusText = "Microphone access denied"
        }
    }

    private func beginRecording() {
        guard let vm else { return }
        if (vm.isAutoMode && vm.hapticsRecordingAuto) || (vm.pushToTalk && vm.hapticsRecordingPTT) {
            vm.haptic(.medium)
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
            vm.isRecording = true
            recordingStartedAt = Date()
            vm.audioLevels = []
            if let sid = recordingSessionId {
                vm.updateStatusText("Recording...", for: sid)
            } else {
                vm.statusText = "Recording..."
            }
            vm.updateLiveActivity()
            startMetering()

            let isBackground = UIApplication.shared.applicationState != .active
            // Always enable VAD in background (only way to stop recording without UI)
            if vm.effectiveVAD || isBackground {
                startVAD()
            }
            // Safety timeout: auto-stop recording after 30s in background
            if isBackground {
                backgroundRecordingTimer?.invalidate()
                backgroundRecordingTimer = Timer.scheduledTimer(
                    withTimeInterval: 30, repeats: false
                ) { [weak self] _ in
                    Task { @MainActor in
                        if self?.vm?.isRecording == true {
                            self?.stopRecording()
                        }
                    }
                }
            }
        } catch {
            print("[mic] Recording error: \(error)")
            vm.statusText = "Recording error"
        }
    }

    /// Stops recording hardware and returns duration + session ID. Does NOT handle send/transcribe logic.
    private func stopRecordingHardware() -> (duration: TimeInterval, sessionId: String?) {
        guard let recorder = audioRecorder, recorder.isRecording else { return (0, nil) }
        recorder.stop()
        audioRecorder = nil
        vm?.isRecording = false
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil
        stopMetering()
        stopVAD()
        backgroundRecordingTimer?.invalidate()
        backgroundRecordingTimer = nil
        let sid = recordingSessionId
        deactivateIfIdle()
        return (duration, sid)
    }

    func stopRecording(discard: Bool = false) {
        guard let vm else { return }
        let (recordingDuration, sid) = stopRecordingHardware()
        // Resume any paused audio from before recording started (matches web pause→record→resume)
        if let pausedSid = pausedAudioSessionId {
            _ = resumePlaybackForSession(pausedSid)
        }
        guard sid != nil || discard else { return }

        guard !discard, let sid else {
            recordingSessionId = nil
            return
        }

        // PTT preview mode: transcribe locally instead of sending to hub
        if vm.showPTTTextField {
            recordingSessionId = nil
            if recordingDuration < 0.5 {
                print("[ptt-preview] Recording too short (\(recordingDuration)s), skipping transcription")
                vm.pttTranscriptionError = "Recording too short. Hold the mic to record, then swipe right."
                return
            }
            if let audioData = try? Data(contentsOf: recordingURL), audioData.count > 1000 {
                print("[ptt-preview] Recording stopped for preview, \(audioData.count) bytes (\(recordingDuration)s)")
                vm.pttTranscriptionError = nil
                vm.isTranscribing = true
                vm.statusText = "Transcribing..."
                transcribeAudio(audioData)
            } else {
                print("[ptt-preview] No audio data at recording URL")
                vm.pttTranscriptionError = "No audio recorded. Hold the mic to record, then swipe right."
            }
            return
        }

        if (vm.isAutoMode && vm.hapticsRecordingAuto) || (vm.pushToTalk && vm.hapticsRecordingPTT) {
            vm.haptic(.light)
        }
        if vm.globalSounds && vm.soundProcessingAuto && vm.isAutoMode { tonePlayer.cueProcessing() }
        vm.isProcessing = true
        vm.updateStatusText("Processing...", for: sid)
        vm.updateLiveActivity()

        if let audioData = try? Data(contentsOf: recordingURL) {
            let b64 = audioData.base64EncodedString()
            // Check if agent is awaiting input or busy
            let isAwaiting = vm.sessionIndex(sid).flatMap { vm.sessions[$0].awaitingInput } ?? false
            let isInterjection = !isAwaiting
            if !vm.isConnected {
                // WS disconnected — stash audio for replay on reconnect (matches web _pendingAudioSend)
                vm.pendingAudioSend = (sessionId: sid, data: audioData, isInterjection: isInterjection)
                vm.statusText = "Reconnecting — audio saved…"
            } else if isInterjection {
                vm.sendJSON(["session_id": sid, "type": "interjection", "data": b64])
            } else {
                vm.sendJSON(["session_id": sid, "type": "audio", "data": b64])
            }
            // Fire parallel transcription for user feedback (both auto and PTT swipe-up)
            if audioData.count > 1000 {
                vm.transcriptPreviewText = ""
                vm.isTranscribingPreview = true
                vm.showTranscriptPreview = true
                transcribeForPreview(audioData)
            }
        } else {
            vm.statusText = "Error reading audio"
            vm.isProcessing = false
            // Send empty audio so hub doesn't hang
            vm.sendJSON(["session_id": sid, "type": "audio", "data": ""])
        }
        recordingSessionId = nil
    }

    func cancelRecording() {
        guard let vm, vm.isRecording, let sid = recordingSessionId else { return }
        stopRecording(discard: true)
        // Suppress next auto-record so cancel doesn't immediately re-trigger
        suppressNextAutoRecord = true
        // Send empty audio so hub doesn't hang
        vm.sendJSON(["session_id": sid, "type": "audio", "data": ""])
        vm.statusText = "Recording cancelled"
    }

    // MARK: - Mic Action

    // Mic button action: context-dependent (debounced to prevent double-taps)
    func micAction() {
        guard let vm else { return }
        let now = Date()
        if let last = lastMicActionTime, now.timeIntervalSince(last) < 0.4 { return }
        lastMicActionTime = now

        if vm.isPlaying {
            // Pause (don't discard) and start recording immediately — matches web behavior
            pauseCurrentPlaybackForSessionSwitch()
            if let sid = vm.activeSessionId {
                startRecording(sessionId: sid)
            }
            return
        } else if vm.isRecording {
            stopRecording()
        } else if vm.micMuted {
            return
        } else if let sid = vm.activeSessionId {
            // User manually tapped mic - clear cancel suppress and pending listen
            suppressNextAutoRecord = false
            if let idx = vm.sessionIndex(sid), vm.sessions[idx].pendingListen {
                vm.sessions[idx].pendingListen = false
            }
            startRecording(sessionId: sid)
        }
    }

    // MARK: - PTT Preview (swipe right to type/transcribe)

    private func transcribeAudio(_ audioData: Data) {
        guard let vm else { return }
        guard let baseURL = vm.httpBaseURL() else {
            print("[ptt-preview] No base URL, aborting transcription")
            vm.isTranscribing = false
            vm.pttTranscriptionError = "Cannot connect to server"
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
                guard let self, let vm = self.vm else { return }
                vm.isTranscribing = false
                vm.statusText = ""
                if let error {
                    print("[ptt-preview] Transcription error: \(error)")
                    vm.pttTranscriptionError = "Transcription failed. Type your message instead."
                    return
                }
                let httpCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard let data,
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    print("[ptt-preview] Invalid response (\(httpCode))")
                    vm.pttTranscriptionError = "Transcription failed. Type your message instead."
                    return
                }
                // Check for server error
                if let serverError = json["error"] as? String {
                    print("[ptt-preview] Server error (\(httpCode)): \(serverError)")
                    vm.pttTranscriptionError = "Transcription error: \(serverError)"
                    return
                }
                if let text = json["text"] as? String, !text.isEmpty {
                    print("[ptt-preview] Got transcription (\(httpCode)): \(text)")
                    vm.pttPreviewText = text
                    vm.pttTranscriptionError = nil
                } else {
                    print("[ptt-preview] Empty text (\(httpCode))")
                    vm.pttTranscriptionError = "No speech detected. Tap the mic to try again."
                }
            }
        }.resume()
    }

    /// Parallel transcription for inline preview display (used by both PTT release and auto-mode send).
    private func transcribeForPreview(_ audioData: Data) {
        guard let vm else { return }
        guard let baseURL = vm.httpBaseURL() else {
            vm.isTranscribingPreview = false
            vm.pttTranscriptionError = "Cannot connect to server"
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
                guard let self, let vm = self.vm else { return }
                vm.isTranscribingPreview = false
                if error != nil {
                    vm.pttTranscriptionError = "Transcription failed"
                    return
                }
                guard let data,
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    vm.pttTranscriptionError = "No speech detected"
                    return
                }
                // Check server error before text (matches transcribeAudio ordering)
                if let serverError = json["error"] as? String {
                    vm.pttTranscriptionError = "Transcription error: \(serverError)"
                    return
                }
                guard let text = json["text"] as? String, !text.isEmpty else {
                    vm.pttTranscriptionError = "No speech detected"
                    return
                }
                vm.transcriptPreviewText = text
                vm.pttTranscriptionError = nil
            }
        }.resume()
    }

    // MARK: - PTT Preview Supporting Methods

    /// Taps inline transcript preview to open keyboard for editing.
    func tapTranscriptToEdit() {
        guard let vm else { return }
        vm.showTranscriptPreview = false
        vm.pttPreviewText = vm.transcriptPreviewText
        vm.showPTTTextField = true
    }

    /// Sends the inline transcript preview text directly.
    func sendTranscriptPreview() {
        guard let vm else { return }
        let text = vm.transcriptPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let sid = vm.activeSessionId else {
            vm.clearTranscriptPreview()
            return
        }
        if vm.hapticsSend { vm.haptic(.medium) }
        if let idx = vm.sessionIndex(sid) { vm.sessions[idx].pendingListen = false }
        vm.sendJSON(["session_id": sid, "type": "text", "text": text])
        vm.clearTranscriptPreview()
    }

    func sendPreviewText() {
        guard let vm else { return }
        let text = vm.pttPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let sid = vm.activeSessionId else {
            dismissPTTTextField()
            return
        }
        if vm.hapticsSend { vm.haptic(.medium) }
        let isAwaiting = vm.sessionIndex(sid).flatMap { vm.sessions[$0].awaitingInput } ?? false
        if isAwaiting {
            if let idx = vm.sessionIndex(sid) { vm.sessions[idx].pendingListen = false }
            vm.sendJSON(["session_id": sid, "type": "text", "text": text])
        } else {
            vm.sendJSON(["session_id": sid, "type": "interjection", "text": text])
        }
        vm.pttPreviewText = ""
        vm.pttTranscriptionError = nil
        vm.showPTTTextField = false
    }

    func dismissPTTTextField() {
        guard let vm else { return }
        if vm.isRecording { stopRecording(discard: true) }
        vm.isTranscribing = false
        vm.showPTTTextField = false
        // If there's text, return to transcript preview instead of fully dismissing
        let text = vm.pttPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            vm.transcriptPreviewText = text
            vm.showTranscriptPreview = true
        }
        vm.pttPreviewText = ""
        vm.pttTranscriptionError = nil
    }

    // MARK: - Push to Talk

    func pttPressed() {
        guard let vm else { return }
        if vm.showTranscriptPreview { vm.clearTranscriptPreview() }
        if vm.isPlaying {
            interruptPlayback()
            pttInterrupted = true
            return
        }
        // Don't record on the same press that interrupted playback
        if pttInterrupted { return }
        // Don't re-trigger if already recording
        if vm.isRecording { return }
        if vm.micMuted { return }
        if let sid = vm.activeSessionId {
            suppressNextAutoRecord = false
            if let idx = vm.sessionIndex(sid), vm.sessions[idx].pendingListen {
                vm.sessions[idx].pendingListen = false
            }
            startRecording(sessionId: sid)
        }
    }

    func pttReleased() {
        pttInterrupted = false
        if vm?.isRecording == true {
            stopRecording()
        }
    }

    /// Called on swipe-up: sends audio to hub immediately. Parallel transcription fires via stopRecording's normal path.
    func pttSwipeUpSend() {
        guard vm?.isRecording == true else { return }
        pttInterrupted = false
        stopRecording()  // normal path: sends audio to hub + fires parallel transcription
    }

    /// Called on normal release (no swipe): stops recording, transcribes for preview. Audio NOT sent to hub.
    func pttReleasedForPreview() {
        guard let vm else { return }
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
            vm.transcriptPreviewText = ""
            vm.isTranscribingPreview = true
            vm.showTranscriptPreview = true
            vm.pttTranscriptionError = nil
            recordingSessionId = nil
            transcribeForPreview(audioData)
        } else {
            recordingSessionId = nil
        }
    }

    /// Called when user swipes right on mic button in PTT mode.
    /// If recording is active, stops and transcribes. Otherwise shows empty text field for typing.
    func enterPTTTextMode() {
        guard let vm else { return }
        vm.pttTranscriptionError = nil
        pttInterrupted = false
        vm.showPTTTextField = true
        if vm.isRecording {
            stopRecording()  // triggers transcription via showPTTTextField branch
        }
    }

    // MARK: - VAD (Voice Activity Detection)

    private func startVAD() {
        stopVAD()
        guard let vm else { return }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        let threshold = Float(vm.vadThreshold)
        let duration = vm.vadSilenceDuration
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
        guard let vm, vm.effectiveAutoInterrupt, !vm.micMuted else { return }
        stopPlaybackVAD()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        let processor = PlaybackVADProcessor { [weak self] in
            Task { @MainActor in
                guard let self, let vm = self.vm, vm.isPlaying else { return }
                self.stopPlaybackVAD()
                self.interruptPlayback()
                if let sid = vm.activeSessionId {
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

    func stopPlaybackVAD() {
        playbackVADEngine?.inputNode.removeTap(onBus: 0)
        playbackVADEngine?.stop()
        playbackVADEngine = nil
        playbackVADProcessor = nil
    }

    // MARK: - Mic Mute

    func handleMuteActivated() {
        guard let vm else { return }
        // Capture sessionId before stopRecording clears it
        if vm.isRecording {
            let sid = recordingSessionId ?? vm.activeSessionId
            stopRecording(discard: true)
            if let sid {
                vm.sendJSON(["session_id": sid, "type": "audio", "data": ""])
            }
        }
        // Send silent audio for any sessions with pending listen
        for i in vm.sessions.indices where vm.sessions[i].pendingListen {
            vm.sendJSON(["session_id": vm.sessions[i].id, "type": "audio", "data": ""])
            vm.sessions[i].pendingListen = false
        }
        vm.updateStatusText("Muted", for: vm.activeSessionId ?? "")
        stopPlaybackVAD()
    }

    // MARK: - Spectrum Analysis

    private func startSpectrumAnalysis() {
        stopSpectrumAnalysis()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate > 0 ? format.sampleRate : 44100

        let processor = SpectrumProcessor(sampleRate: sampleRate) { [weak self] bands in
            Task { @MainActor in
                self?.vm?.spectrumBands = bands
            }
        }
        spectrumProcessor = processor
        installSpectrumTap(on: input, format: format, processor: processor)

        do {
            try engine.start()
            spectrumEngine = engine
        } catch {
            print("[spectrum] Engine start failed: \(error)")
            input.removeTap(onBus: 0)
        }
    }

    private func stopSpectrumAnalysis() {
        spectrumEngine?.inputNode.removeTap(onBus: 0)
        spectrumEngine?.stop()
        spectrumEngine = nil
        spectrumProcessor = nil
        vm?.spectrumBands = Array(repeating: 0, count: SpectrumProcessor.bandCount)
    }

    // MARK: - Audio Metering

    private func startMetering() {
        stopMetering()
        startSpectrumAnalysis()
        // Use .common RunLoop mode so the timer fires during scroll gestures (.UITrackingRunLoopMode)
        let timer = Timer(timeInterval: 0.016, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, let vm = self.vm,
                      let recorder = self.audioRecorder, recorder.isRecording else {
                    self?.stopMetering()  // self-cancel if recording stopped unexpectedly
                    return
                }
                recorder.updateMeters()
                // peakPower is in dB (-160 to 0), normalize to 0...1, apply decay
                let db = recorder.peakPower(forChannel: 0)
                let peak = max(0, min(1, CGFloat((db + 50) / 50)))
                let normalized = max(peak, self.prevMeterLevel * 0.25)
                self.prevMeterLevel = normalized
                vm.audioLevels.append(normalized)
                if vm.audioLevels.count > self.maxLevelSamples {
                    vm.audioLevels.removeFirst(vm.audioLevels.count - self.maxLevelSamples)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meteringTimer = timer
    }

    private func stopMetering() {
        meteringTimer?.invalidate()
        meteringTimer = nil
        stopSpectrumAnalysis()
    }
}

// MARK: - AVAudioPlayerDelegate

extension AudioManager: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer, successfully flag: Bool
    ) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor in
            guard let vm = self.vm else { return }
            // Use identity comparison — not heuristic state — to identify which player finished
            if let tts = self.ttsPlayer, ObjectIdentifier(tts) == playerID {
                self.ttsPlayer = nil
                vm.ttsPlayingMessageId = nil
                return
            }

            let sid = self.playingSessionId ?? ""

            self.stopPlaybackVAD()
            vm.isPlaying = false  // clear isPlaying before playingSessionId — isSpeaking didSet depends on order

            // Drain next chunk before sending playback_done (matches web _playNextQueued behavior:
            // only send playback_done when the per-session queue is fully empty)
            if !sid.isEmpty, let idx = vm.sessionIndex(sid),
                !vm.sessions[idx].audioBuffer.isEmpty
            {
                self.drainAudioBuffer(sid)
                return
            }

            self.playingSessionId = nil
            self.deactivateIfIdle()
            if !sid.isEmpty {
                vm.sendJSON(["session_id": sid, "type": "playback_done"])
            }
            vm.updateLiveActivity()

            // Handle deferred listen: listening arrived while audio was playing
            if !sid.isEmpty, let idx = vm.sessionIndex(sid),
                vm.sessions[idx].pendingListen, sid == vm.activeSessionId
            {
                let isBackground = UIApplication.shared.applicationState != .active
                let bgAutoRecord = isBackground && vm.backgroundMode && vm.isAutoMode
                if !vm.micMuted && (vm.effectiveAutoRecord || bgAutoRecord) {
                    vm.sessions[idx].pendingListen = false
                    if vm.globalSounds && vm.soundListeningAuto { self.tonePlayer.cueListening() }
                    self.startRecording(sessionId: sid)
                }
            }
            // Background safety net: hub sends "listening" after playback_done,
            // so pendingListen may not be set yet. Schedule a cancellable delayed re-check.
            else if !sid.isEmpty, sid == vm.activeSessionId,
                UIApplication.shared.applicationState != .active,
                vm.backgroundMode, vm.isAutoMode, !vm.micMuted
            {
                let capturedSid = sid
                self.backgroundListenWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    Task { @MainActor in
                        guard let self, let vm = self.vm,
                            let idx = vm.sessionIndex(capturedSid),
                            vm.sessions[idx].pendingListen,
                            !vm.isRecording, !vm.isPlaying,
                            capturedSid == vm.activeSessionId,
                            UIApplication.shared.applicationState != .active
                        else { return }
                        vm.sessions[idx].pendingListen = false
                        self.suppressNextAutoRecord = false
                        if vm.globalSounds && vm.soundListeningAuto { self.tonePlayer.cueListening() }
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
            guard let vm = self.vm else { return }
            // TTS message decode error — just clear state
            if let tts = self.ttsPlayer, ObjectIdentifier(tts) == playerID {
                self.ttsPlayer = nil
                vm.ttsPlayingMessageId = nil
                return
            }
            let sid = self.playingSessionId ?? ""
            self.stopPlaybackVAD()
            vm.isPlaying = false
            self.playingSessionId = nil
            vm.statusText = "Audio decode error"
            // Drain stale buffer so it doesn't play on next session switch
            if !sid.isEmpty, let idx = vm.sessionIndex(sid) {
                vm.sessions[idx].audioBuffer.removeAll()
            }
            if !sid.isEmpty {
                vm.sendJSON(["session_id": sid, "type": "playback_done"])
            }
        }
    }
}
