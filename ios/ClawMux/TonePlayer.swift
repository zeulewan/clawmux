import AVFoundation
import Foundation

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
