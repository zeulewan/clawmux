import ActivityKit
import Foundation
import UIKit

// MARK: - Audio Delegation
// Delegates to AudioManager. All @Published audio state stays on ViewModel.

extension ClawMuxViewModel {

    func startThinkingSound()  { audio.startThinkingSound() }
    func stopThinkingSound()   { audio.stopThinkingSound() }

    func startRecording(sessionId: String? = nil)  { audio.startRecording(sessionId: sessionId) }
    func stopRecording(discard: Bool = false)       { audio.stopRecording(discard: discard) }
    func cancelRecording()                          { audio.cancelRecording() }

    func pausePlayback()     { audio.pausePlayback() }
    func resumePlayback()    { audio.resumePlayback() }
    func interruptPlayback() { audio.interruptPlayback() }

    func micAction() { audio.micAction() }

    func pttPressed()            { audio.pttPressed() }
    func pttReleased()           { audio.pttReleased() }
    func pttSwipeUpSend()        { audio.pttSwipeUpSend() }
    func pttReleasedForPreview() { audio.pttReleasedForPreview() }
    func enterPTTTextMode()      { audio.enterPTTTextMode() }

    func tapTranscriptToEdit()   { audio.tapTranscriptToEdit() }
    func sendTranscriptPreview() { audio.sendTranscriptPreview() }
    func sendPreviewText()       { audio.sendPreviewText() }
    func dismissPTTTextField()   { audio.dismissPTTTextField() }

    func playMessageTTS(messageId: UUID, text: String, voice: String?) {
        audio.playMessageTTS(messageId: messageId, text: text, voice: voice)
    }
    func stopMessageTTS() { audio.stopMessageTTS() }

    func clearTranscriptPreview() {
        showTranscriptPreview = false
        transcriptPreviewText = ""
        isTranscribingPreview = false
        pttTranscriptionError = nil
    }

    // MARK: - Interrupt

    func sendInterrupt() {
        // Always suppress auto-record after an interrupt — whether agent is thinking or speaking
        audio.currentSuppressNextAutoRecord = true
        // Clear any existing pendingListen so interrupt cannot trigger recording via session switch
        if let sid = activeSessionId, let idx = sessionIndex(sid) {
            sessions[idx].pendingListen = false
        }
        // If audio is playing, stop it immediately (matches web stop-agent-speaking)
        if isPlaying || isPlaybackPaused { interruptPlayback() }
        guard let sid = activeSessionId, let baseURL = httpBaseURL() else { return }
        // Match web: POST /api/sessions/{id}/interrupt (not a WS message — server has no WS handler for "interrupt")
        var req = URLRequest(url: baseURL.appendingPathComponent("api/sessions/\(sid)/interrupt"))
        req.httpMethod = "POST"
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }

    // MARK: - Pending Audio Replay

    /// Replay audio stashed during a connection drop — sent as interjection so the hub
    /// transcribes and queues it correctly (mirrors web _flushPendingAudio called on WS open).
    func flushPendingAudio() {
        guard let pending = pendingAudioSend, isConnected else { return }
        pendingAudioSend = nil
        let b64 = pending.data.base64EncodedString()
        let type = pending.isInterjection ? "interjection" : "audio"
        #if DEBUG
        print("[audio] Flushing stashed audio as \(type) for session \(pending.sessionId)")
        #endif
        sendJSON(["session_id": pending.sessionId, "type": type, "data": b64])
        updateStatusText("Transcribing…", for: pending.sessionId)
    }

    // MARK: - Live Activity

    func startLiveActivity(sessionId: String) {
        guard liveActivityEnabled else { return }
        guard (isAutoMode && liveActivityAuto) || (pushToTalk && liveActivityPTT) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return }

        let attributes = ClawMuxActivityAttributes(sessionId: sessionId)
        let state = ClawMuxActivityAttributes.ContentState(
            voiceName: session.label,
            status: voiceHubStatus(for: session),
            lastMessage: messagesBySession[sessionId]?.last(where: { $0.role == "assistant" })?
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

    func updateLiveActivity() {
        guard let activity = currentActivity,
            let sessionId = activeSessionId,
            let session = sessions.first(where: { $0.id == sessionId })
        else { return }

        let state = ClawMuxActivityAttributes.ContentState(
            voiceName: session.label,
            status: voiceHubStatus(for: session),
            lastMessage: messagesBySession[sessionId]?.last(where: { $0.role == "assistant" })?
                .text.prefix(80).description ?? "",
            inputMode: inputMode
        )

        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    func endLiveActivity() {
        guard let activity = currentActivity else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        currentActivity = nil
    }

    func endStaleLiveActivities() {
        // Clean up any activities left over from a previous launch (e.g. force-kill)
        Task {
            for activity in Activity<ClawMuxActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    func voiceHubStatus(for session: VoiceSession) -> ClawMuxStatus {
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

    func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard globalHaptics else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    func haptic(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard globalHaptics else { return }
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}
