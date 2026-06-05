import Foundation
import SwiftData

/// Buffers 10 Hz motion samples and, every 30 seconds, computes the day-one accelerometer
/// feature set and persists one SensorWindow. Incremental per-window writes mean a crash
/// loses at most one window. Lights up the `window` and `persist` log categories.
///
/// Feature set chosen per the research: RMS + jerk RMS + a band-passed-style activity count
/// + ENMO + immobility-run context + tilt/posture. Thresholds that gate "movement" are kept
/// in SomnyaConfig (auto-scaling per night is a later refinement; for now a sane default).
@MainActor
final class WindowAggregator {
    private let context: ModelContext
    private weak var session: SleepSession?

    private let windowSeconds: Double = 30
    private var buffer: [MotionSample] = []
    private var windowStart: Date?

    /// Running immobility-run length across windows (consecutive low-movement windows).
    private var immobilityRun = 0
    /// Previous window's mean tilt, to count posture changes.
    private var lastTilt: Double?

    /// Pulled at each flush to attach audio features (breathing) to the window. Returns nil when
    /// the mic is off or has no trustworthy data — the accel-only window is still written.
    /// Kept as a closure so the aggregator stays decoupled from the audio layer.
    var audioFeatureProvider: (() -> AudioAnalyzer.WindowFeatures?)?

    init(context: ModelContext, session: SleepSession) {
        self.context = context
        self.session = session
    }

    /// Feed one decimated motion sample. Flushes a window when 30s have elapsed.
    func ingest(_ sample: MotionSample) {
        if windowStart == nil { windowStart = sample.timestamp }
        buffer.append(sample)

        if let start = windowStart, sample.timestamp.timeIntervalSince(start) >= windowSeconds {
            flush(at: start)
        }
    }

    /// Finalize whatever's buffered (called on session stop so the last partial window isn't lost).
    func finalize() {
        if let start = windowStart, !buffer.isEmpty {
            flush(at: start, partial: true)
        }
    }

    private func flush(at start: Date, partial: Bool = false) {
        guard let session, !buffer.isEmpty else { buffer.removeAll(); windowStart = nil; return }
        let samples = buffer
        buffer.removeAll()
        windowStart = nil

        let features = Self.computeFeatures(samples)

        // Immobility-run context: increment if this window is "still", else reset.
        if features.activityCount < SomnyaConfig.movementThreshold {
            immobilityRun += 1
        } else {
            immobilityRun = 0
        }

        // Posture change: tilt moved more than the configured delta since last window.
        var postureChanges = 0
        if let prev = lastTilt, abs(features.meanTilt - prev) > SomnyaConfig.postureChangeRadians {
            postureChanges = 1
        }
        lastTilt = features.meanTilt

        // Pull audio features for this window (nil if mic off / no clear signal).
        let audio = audioFeatureProvider?()

        let window = SensorWindow(
            startTime: start,
            windowSeconds: partial ? Date().timeIntervalSince(start) : windowSeconds,
            accelRMS: features.rms,
            accelJerkRMS: features.jerkRMS,
            accelActivityCount: features.activityCount,
            accelENMOMean: features.enmoMean,
            immobilityRunLength: immobilityRun,
            tiltAngle: features.meanTilt,
            postureChangeCount: postureChanges,
            audioRMS: audio?.audioRMS,
            audioFloor: audio?.audioFloor,
            breathingRate: audio?.breathingRate,
            breathingRateVariability: audio?.breathingRateVariability,
            breathingConfidence: audio?.confidence,
            audioEnvelope: audio?.envelope,
            audioEnvelopeFiltered: audio?.filteredEnvelope,
            melBandEnergies: audio?.melBands
        )
        window.session = session
        context.insert(window)

        // Always surface the audio diagnostic — on success the rate+conf, on nil the REASON +
        // envelope count + rms/floor, so a "no breathing" night is debuggable, not a mystery.
        let breathStr: String
        if let a = audio {
            if let rate = a.breathingRate {
                breathStr = String(format: "breath=%.1fbrpm conf=%.2f env=%d rms=%.4f floor=%.4f",
                                   rate, a.confidence, a.envelopeSampleCount, a.audioRMS, a.audioFloor)
            } else {
                breathStr = String(format: "breath=nil [%@] env=%d rms=%.4f floor=%.4f",
                                   a.reason, a.envelopeSampleCount, a.audioRMS, a.audioFloor)
            }
        } else {
            breathStr = "breath=nil [no audio — mic off or no buffers yet]"
        }
        SomnyaLog.window(String(format: "window n=%d rms=%.3f jerk=%.3f count=%.3f enmo=%.3f immobRun=%d %@%@",
                                samples.count, features.rms, features.jerkRMS, features.activityCount,
                                features.enmoMean, immobilityRun, breathStr, partial ? " (partial)" : ""))

        do {
            try context.save()
            SomnyaLog.persist("SensorWindow saved start=\(start)")
        } catch {
            SomnyaLog.persist("FAILED to save SensorWindow: \(error)")
        }
    }

    // MARK: - Feature computation

    struct Features {
        let rms: Double
        let jerkRMS: Double
        let activityCount: Double
        let enmoMean: Double
        let meanTilt: Double
    }

    /// Pure function so it's unit-testable without sensors. Computes the day-one feature set
    /// from a window of decimated samples.
    static func computeFeatures(_ s: [MotionSample]) -> Features {
        guard !s.isEmpty else {
            return Features(rms: 0, jerkRMS: 0, activityCount: 0, enmoMean: 0, meanTilt: 0)
        }

        // Per-sample acceleration magnitude.
        let mags = s.map { sqrt($0.ax * $0.ax + $0.ay * $0.ay + $0.az * $0.az) }

        // RMS of magnitude.
        let rms = sqrt(mags.map { $0 * $0 }.reduce(0, +) / Double(mags.count))

        // ENMO: Euclidean norm minus one (g), negatives clipped — but userAcceleration already
        // has gravity removed, so this is effectively mean magnitude above zero.
        let enmoMean = mags.map { max($0, 0) }.reduce(0, +) / Double(mags.count)

        // Jerk RMS: RMS of the first difference of magnitude (the specificity-boosting feature).
        var jerks: [Double] = []
        jerks.reserveCapacity(max(0, mags.count - 1))
        for i in 1..<max(mags.count, 1) {
            jerks.append(mags[i] - mags[i - 1])
        }
        let jerkRMS = jerks.isEmpty ? 0 : sqrt(jerks.map { $0 * $0 }.reduce(0, +) / Double(jerks.count))

        // Activity count proxy: sum of absolute first differences (integrated movement).
        let activityCount = jerks.map { abs($0) }.reduce(0, +)

        // Mean tilt from attitude (pitch+roll magnitude as a simple posture scalar).
        let meanTilt = s.map { sqrt($0.pitch * $0.pitch + $0.roll * $0.roll) }
            .reduce(0, +) / Double(s.count)

        return Features(rms: rms, jerkRMS: jerkRMS, activityCount: activityCount,
                        enmoMean: enmoMean, meanTilt: meanTilt)
    }
}
