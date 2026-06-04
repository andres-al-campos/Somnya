import Foundation
import AVFoundation

/// Turns raw mic buffers into breathing features WITHOUT keeping the raw audio. Breathing isn't
/// in the audio spectrum you'd hear — it's in the slow *envelope* of loudness (the gentle
/// rise/fall as you inhale/exhale). So we:
///   1. Per buffer: compute RMS loudness, update a rolling noise floor, append to a slow
///      (~10 Hz) envelope buffer.
///   2. Per 30s window: autocorrelate that envelope and find its dominant slow rhythm in the
///      6–30 brpm band → breathing rate (or nil when there's no trustworthy periodicity).
///
/// Memory stays tiny: we keep an envelope (a few hundred floats), never the 2 kHz waveform.
/// All the math lives in pure static functions so it's unit-testable without a microphone.
final class AudioAnalyzer {

    // MARK: - Live state (written on the audio thread, read at window flush)

    /// Most-recent buffer RMS (instant loudness). Lock-light: scalar writes are atomic enough
    /// for a heartbeat-level read; the window snapshot is what matters for persistence.
    private(set) var lastRMS: Double = 0

    /// Rolling noise floor — the quiet baseline, adapted slowly so transient sounds don't move it.
    private(set) var noiseFloor: Double = 0
    private var floorInitialized = false

    /// Slow loudness envelope (≈ audioEnvelopeHz). This is the breathing signal. Capped so a
    /// long night can't grow it unbounded — we only need the current window's worth plus margin.
    private var envelope: [Double] = []
    private let envelopeCapacity: Int

    /// Accumulator for downsampling buffer-rate RMS → envelope-rate samples.
    private var sampleClock: Double = 0
    private var hardwareSampleRate: Double = 48000

    /// Previous window's breathing rate, for breath-to-breath variability across windows.
    private var lastBreathingRate: Double?

    private let queue = DispatchQueue(label: "com.aurende.somnya.audioanalyzer")

    init() {
        // Keep ~3 windows of envelope as headroom (window flush trims it anyway).
        envelopeCapacity = Int(SomnyaConfig.audioEnvelopeHz * SomnyaConfig.windowSeconds * 3)
    }

    // MARK: - Buffer ingestion (called from the AVAudioEngine tap, off the main thread)

    /// Process one mic buffer: update loudness, noise floor, and the envelope.
    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        hardwareSampleRate = buffer.format.sampleRate

        // RMS of this buffer = instantaneous loudness.
        var sumSq: Double = 0
        for i in 0..<n {
            let v = Double(channel[i])
            sumSq += v * v
        }
        let rms = sqrt(sumSq / Double(n))

        queue.sync {
            lastRMS = rms

            // Rolling noise floor: track the quiet baseline. Seed on first buffer, then only
            // let it drift toward quieter values quickly and louder values slowly, so speech /
            // movement transients don't inflate the "quiet" baseline.
            if !floorInitialized {
                noiseFloor = rms
                floorInitialized = true
            } else if rms < noiseFloor {
                noiseFloor = rms  // quiet revealed: snap down
            } else {
                noiseFloor += SomnyaConfig.noiseFloorSmoothing * (rms - noiseFloor)
            }

            // Downsample buffer-rate RMS into the ~10 Hz envelope. One buffer covers
            // n/sampleRate seconds; emit floor(that * envelopeHz) envelope samples.
            let bufferSeconds = Double(n) / hardwareSampleRate
            sampleClock += bufferSeconds * SomnyaConfig.audioEnvelopeHz
            while sampleClock >= 1 {
                envelope.append(rms)
                sampleClock -= 1
            }
            if envelope.count > envelopeCapacity {
                envelope.removeFirst(envelope.count - envelopeCapacity)
            }
        }
    }

    // MARK: - Window snapshot (called at 30s flush, on the main actor)

    /// Audio features for the window that just closed. Any field may be nil when the signal
    /// doesn't support a trustworthy estimate — we never fabricate a breathing rate.
    struct WindowFeatures {
        let audioRMS: Double
        let audioFloor: Double
        let breathingRate: Double?
        let breathingRateVariability: Double?
        let confidence: Double
    }

    /// Snapshot the current window's audio features and clear the envelope for the next window.
    /// Returns nil only if we have no audio at all (mic off / no buffers yet).
    func snapshotWindow() -> WindowFeatures? {
        queue.sync {
            guard floorInitialized else { return nil }
            let env = envelope
            envelope.removeAll(keepingCapacity: true)

            let result = Self.estimateBreathing(
                envelope: env,
                envelopeHz: SomnyaConfig.audioEnvelopeHz
            )

            // Variability = absolute change from the previous trusted window's rate.
            var variability: Double?
            if let rate = result.bpm, let prev = lastBreathingRate {
                variability = abs(rate - prev)
            }
            if let rate = result.bpm { lastBreathingRate = rate }

            return WindowFeatures(
                audioRMS: lastRMS,
                audioFloor: noiseFloor,
                breathingRate: result.bpm,
                breathingRateVariability: variability,
                confidence: result.confidence
            )
        }
    }

    /// Reset between sessions.
    func reset() {
        queue.sync {
            lastRMS = 0
            noiseFloor = 0
            floorInitialized = false
            envelope.removeAll(keepingCapacity: true)
            sampleClock = 0
            lastBreathingRate = nil
        }
    }

    // MARK: - Pure breathing estimation (unit-testable, no audio dependencies)

    struct BreathingEstimate {
        /// Breaths per minute, or nil when no trustworthy periodicity was found.
        let bpm: Double?
        /// Normalized autocorrelation peak height [0...1] — how clear the rhythm was.
        let confidence: Double
    }

    /// Estimate breathing rate from a loudness envelope via autocorrelation.
    ///
    /// Method: detrend (remove DC), autocorrelate, then search lags corresponding to the
    /// 6–30 brpm band for the strongest normalized peak. The peak's lag → period → rate; the
    /// peak's height → confidence. Returns nil when the best peak is below the confidence
    /// threshold (no clear breathing rhythm — too quiet or too noisy).
    static func estimateBreathing(envelope: [Double], envelopeHz: Double) -> BreathingEstimate {
        let n = envelope.count
        // Need at least ~2 full cycles of the slowest breath to estimate reliably.
        let minSamplesNeeded = Int((60.0 / SomnyaConfig.breathingMinBPM) * envelopeHz * 2)
        guard n >= minSamplesNeeded, n > 4 else {
            return BreathingEstimate(bpm: nil, confidence: 0)
        }

        // Detrend: subtract the mean so the DC component doesn't dominate the autocorrelation.
        let mean = envelope.reduce(0, +) / Double(n)
        let x = envelope.map { $0 - mean }

        // Zero-lag energy (the normalizer). If essentially flat, there's no signal.
        let energy = x.map { $0 * $0 }.reduce(0, +)
        guard energy > 1e-12 else {
            return BreathingEstimate(bpm: nil, confidence: 0)
        }

        // Lag bounds from the breathing band. Faster breaths = shorter lag.
        let minLag = Int((60.0 / SomnyaConfig.breathingMaxBPM) * envelopeHz)
        let maxLag = min(n - 1, Int((60.0 / SomnyaConfig.breathingMinBPM) * envelopeHz))
        guard maxLag > minLag, minLag >= 1 else {
            return BreathingEstimate(bpm: nil, confidence: 0)
        }

        // Find the strongest normalized autocorrelation peak within the band.
        var bestLag = -1
        var bestCorr = -Double.infinity
        for lag in minLag...maxLag {
            var sum: Double = 0
            for i in 0..<(n - lag) {
                sum += x[i] * x[i + lag]
            }
            let normCorr = sum / energy
            if normCorr > bestCorr {
                bestCorr = normCorr
                bestLag = lag
            }
        }

        guard bestLag > 0, bestCorr >= SomnyaConfig.breathingMinConfidence else {
            return BreathingEstimate(bpm: nil, confidence: max(0, bestCorr))
        }

        // lag (samples) → period (seconds) → breaths per minute.
        let periodSeconds = Double(bestLag) / envelopeHz
        let bpm = 60.0 / periodSeconds
        return BreathingEstimate(bpm: bpm, confidence: bestCorr)
    }
}
