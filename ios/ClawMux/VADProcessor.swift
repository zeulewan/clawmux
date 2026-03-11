import AVFoundation
import Foundation

// MARK: - VAD Tap Helper (must be outside @MainActor to avoid isolation inheritance)

func installVADTap(
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

func installPlaybackVADTap(
    on input: AVAudioInputNode, format: AVAudioFormat, processor: PlaybackVADProcessor
) {
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
        processor.processBuffer(buffer)
    }
}
