import AVFoundation
import Accelerate
import Foundation

// MARK: - Spectrum Tap Helper (must be outside @MainActor to avoid isolation inheritance)

func installSpectrumTap(
    on input: AVAudioInputNode,
    format: AVAudioFormat,
    processor: SpectrumProcessor
) {
    input.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, _ in
        processor.processBuffer(buffer)
    }
}

// MARK: - Spectrum Processor

/// Computes a 12-band log-spaced FFT power spectrum from PCM audio buffers.
/// Designed to run on the AVAudioEngine realtime tap thread.
/// Thread-safe via @unchecked Sendable — only called from one audio tap at a time.
final class SpectrumProcessor: @unchecked Sendable {

    static let bandCount = 12

    private let fftSize = 512
    private let log2n: vDSP_Length
    private var fftSetup: FFTSetup?

    // Pre-allocated buffers — avoids heap allocation on the audio realtime thread
    private var window: [Float]
    private var windowed: [Float]
    private var realParts: [Float]
    private var imagParts: [Float]
    private var magnitudes: [Float]
    private var prevBands: [Float]

    // Band configuration
    private let bandEdges: [Int]        // bandCount+1 FFT bin indices
    private let decayFactors: [Float]   // per-band: low=slower, high=faster

    private let onBandsUpdated: @Sendable ([CGFloat]) -> Void

    init(sampleRate: Double = 44100, onBandsUpdated: @escaping @Sendable ([CGFloat]) -> Void) {
        let n = 512
        let l2n = vDSP_Length(log2f(Float(n)))
        self.log2n = l2n
        self.fftSetup = vDSP_create_fftsetup(l2n, FFTRadix(kFFTRadix2))
        self.onBandsUpdated = onBandsUpdated

        // Hann window for spectral leakage reduction
        var win = [Float](repeating: 0, count: n)
        vDSP_hann_window(&win, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        self.window = win

        self.windowed = [Float](repeating: 0, count: n)
        self.realParts = [Float](repeating: 0, count: n / 2)
        self.imagParts = [Float](repeating: 0, count: n / 2)
        self.magnitudes = [Float](repeating: 0, count: n / 2)
        self.prevBands = [Float](repeating: 0, count: Self.bandCount)

        // 13 frequency edges → 12 log-spaced bands
        // ~60Hz, 120Hz, 250Hz, 500Hz, 1k, 2k, 4k, 8k, 12k, 16k, 20kHz
        let freqEdges: [Float] = [20, 60, 120, 250, 500, 1000, 2000, 4000, 8000, 12000, 16000, 20000, 22050]
        let binWidth = Float(sampleRate) / Float(n)
        self.bandEdges = freqEdges.map { f in max(1, min(n / 2 - 1, Int(f / binWidth))) }

        // Decay: band 0 (low) = 0.80 (slow), band 11 (high) = 0.35 (fast)
        self.decayFactors = (0..<Self.bandCount).map { b in
            0.80 - Float(b) / Float(Self.bandCount - 1) * 0.45
        }
    }

    deinit {
        if let setup = fftSetup { vDSP_destroy_fftsetup(setup) }
    }

    func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let fftSetup,
              let channelData = buffer.floatChannelData?[0] else { return }
        guard Int(buffer.frameLength) >= fftSize else { return }

        // Apply Hann window to time-domain samples
        vDSP_vmul(channelData, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        // Pack real samples into split-complex, run forward FFT, compute squared magnitudes
        realParts.withUnsafeMutableBufferPointer { rBuf in
            imagParts.withUnsafeMutableBufferPointer { iBuf in
                var splitC = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                windowed.withUnsafeMutableBufferPointer { winBuf in
                    winBuf.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self, capacity: fftSize / 2
                    ) { cPtr in
                        vDSP_ctoz(cPtr, 2, &splitC, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &splitC, 1, log2n, FFTDirection(FFT_FORWARD))
                magnitudes.withUnsafeMutableBufferPointer { magBuf in
                    vDSP_zvmags(&splitC, 1, magBuf.baseAddress!, 1, vDSP_Length(fftSize / 2))
                }
            }
        }

        // Normalize: vDSP_fft_zrip scales by 2; divide by N^2 for proper amplitude
        var scale = Float(2.0) / Float(fftSize * fftSize)
        magnitudes.withUnsafeMutableBufferPointer { magBuf in
            let ptr = magBuf.baseAddress!
            vDSP_vsmul(ptr, 1, &scale, ptr, 1, vDSP_Length(fftSize / 2))
        }

        // Group bins into bands, apply attack/decay smoothing
        var result = [CGFloat](repeating: 0, count: Self.bandCount)
        for b in 0..<Self.bandCount {
            let lo = bandEdges[b]
            let hi = min(bandEdges[b + 1], fftSize / 2)
            guard hi > lo else { continue }
            let binCount = hi - lo
            var sum: Float = 0
            magnitudes.withUnsafeBufferPointer { magBuf in
                vDSP_sve(magBuf.baseAddress! + lo, 1, &sum, vDSP_Length(binCount))
            }
            // RMS → dB → normalize to 0..1 over -60..0 dB range
            let rms = sqrtf(sum / Float(binCount))
            let db = 20.0 * log10f(rms + 1e-8)
            let level = max(0.0, min(1.0, (db + 60.0) / 60.0))
            // Instant attack, per-band decay
            let prev = prevBands[b]
            prevBands[b] = level >= prev ? level : prev * decayFactors[b]
            result[b] = CGFloat(prevBands[b])
        }
        onBandsUpdated(result)
    }
}
