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

    /// Raw 50 Hz accel/gyro magnitudes for the current window — the dense stream the BCG/breathing
    /// envelope is downsampled from. Kept separate from `buffer` (10 Hz) because the envelope needs
    /// the full capture rate to resolve heartbeat timing; the movement features don't.
    private var rawAccelMags: [Double] = []
    private var rawGyroMags: [Double] = []
    private var rawGravity: [(x: Double, y: Double, z: Double)] = []
    private var rawVertical: [Double] = []

    /// Heart segments made block by block as windows land; see `HeartbeatLive`.
    private var heart = HeartbeatLive()
    /// Start of the first saved window: window minutes count from it, as `SleepOnset.minutesFromStart` does.
    private var firstWindowStart: Date?
    private var lastWindow: SensorWindow?

    /// Running immobility-run length across windows (consecutive low-movement windows).
    private var immobilityRun = 0
    /// Previous window's mean tilt, to count posture changes.
    private var lastTilt: Double?

    /// Pulled at each flush to attach audio features (breathing) to the window. Returns nil when
    /// the mic is off or has no trustworthy data — the accel-only window is still written.
    /// Kept as a closure so the aggregator stays decoupled from the audio layer.
    var audioFeatureProvider: (() -> AudioAnalyzer.WindowFeatures?)?

    /// Pulled at each flush for the latest barometer reading (pressure kPa, relative altitude m).
    /// nil when no barometer. Kept as a closure so the aggregator stays decoupled from the sensor.
    var barometerProvider: (() -> (pressureKPa: Double?, relativeAltitudeM: Double?))?

    /// Called with each window once it's saved (not the partial one flushed at stop).
    var onWindow: ((SensorWindow) -> Void)?
    /// Every saved window, the partial last one too.
    var onSaved: ((SensorWindow) -> Void)?

    init(context: ModelContext, session: SleepSession) {
        self.context = context
        self.session = session
    }

    /// Feed one decimated (10 Hz) motion sample. Flushes a window when 30s have elapsed.
    func ingest(_ sample: MotionSample) {
        if windowStart == nil { windowStart = sample.timestamp }
        buffer.append(sample)

        if let start = windowStart, sample.timestamp.timeIntervalSince(start) >= windowSeconds {
            flush(at: start)
        }
    }

    /// Feed one raw 50 Hz accel+gyro magnitude (the dense envelope source). These accumulate into
    /// the current window and are downsampled to the envelope rate at flush. The 10 Hz `ingest`
    /// path still owns window timing/flushing — this only accrues the dense samples in between.
    func ingestRawMagnitude(accelMag: Double, gyroMag: Double,
                            gravity: (x: Double, y: Double, z: Double), vertical: Double) {
        rawAccelMags.append(accelMag)
        rawGyroMags.append(gyroMag)
        rawGravity.append(gravity)
        rawVertical.append(vertical)
    }

    /// Finalize whatever's buffered (called on session stop so the last partial window isn't lost).
    func finalize() {
        if let start = windowStart, !buffer.isEmpty {
            flush(at: start, partial: true)
        }
        closeHeartbeat()
    }

    /// Make the last heart segments from the envelope still waiting for its padding and save them
    /// on the last window. Called when the night ends, whether or not the partial window is kept.
    func closeHeartbeat() {
        let segments = heart.finish()
        guard let window = lastWindow, !segments.isEmpty else { return }
        window.heartSegments = (window.heartSegments ?? Data()) + Heartbeat.encode(segments)
        do {
            try context.save()
        } catch {
            SomnyaLog.persist("FAILED to save the last heart segments: \(error)")
        }
    }

    private func flush(at start: Date, partial: Bool = false) {
        guard let session, !buffer.isEmpty else {
            buffer.removeAll(); rawAccelMags.removeAll(); rawGyroMags.removeAll(); rawGravity.removeAll(); rawVertical.removeAll()
            windowStart = nil; return
        }
        let samples = buffer
        let rawAccel = rawAccelMags
        let rawGyro = rawGyroMags
        let rawGrav = rawGravity
        let vertical = rawVertical.isEmpty ? nil : Data(float32s: Self.downsample(
            rawVertical, fromHz: SomnyaConfig.captureHz, toHz: SomnyaConfig.gravityEnvelopeHz).map { Float32($0) })
        buffer.removeAll()
        rawAccelMags.removeAll()
        rawGyroMags.removeAll()
        rawGravity.removeAll()
        rawVertical.removeAll()
        windowStart = nil

        let features = Self.computeFeatures(samples, rawAccelMags: rawAccel, rawGyroMags: rawGyro,
                                            rawGravity: rawGrav)

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
        // Pull the latest barometer reading (nil if no barometer / not yet delivered).
        let baro = barometerProvider?()

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
            accelEnvelope: features.accelEnvelope.isEmpty ? nil : features.accelEnvelope,
            gyroMean: features.gyroMean,
            gravityEnvelope: features.gravityEnvelope,
            gravityX: features.gravityX,
            gravityY: features.gravityY,
            gravityZ: features.gravityZ,
            pressureKPa: baro?.pressureKPa,
            relativeAltitudeM: baro?.relativeAltitudeM,
            audioRMS: audio?.audioRMS,
            audioFloor: audio?.audioFloor,
            breathingRate: audio?.breathingRate,
            breathingRateVariability: audio?.breathingRateVariability,
            breathingConfidence: audio?.confidence,
            audioEnvelope: audio?.envelope,
            audioEnvelopeFiltered: audio?.filteredEnvelope,
            melBandEnergies: audio?.melBands
        )
        window.verticalAccel = vertical
        window.session = session
        let first = firstWindowStart ?? start
        firstWindowStart = first
        window.heartSegments = Heartbeat.encode(
            heart.append(features.accelEnvelope, minute: start.timeIntervalSince(first) / 60))
        lastWindow = window
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
        onSaved?(window)
        if !partial { onWindow?(window) }
    }

    // MARK: - Feature computation

    struct Features {
        let rms: Double
        let jerkRMS: Double
        let activityCount: Double
        let enmoMean: Double
        let meanTilt: Double
        /// Dense accel-magnitude envelope (~accelEnvelopeHz, gravity-removed) for offline
        /// breathing-from-bed-motion analysis. Empty if the window had no usable samples.
        let accelEnvelope: [Double]
        /// Mean gyro magnitude (rad/s), for pickup detection.
        let gyroMean: Double
        /// Gravity at gravityEnvelopeHz as Float32 x,y,z triples; nil without raw samples.
        let gravityEnvelope: Data?
        /// Mean gravity vector over the window (g). Encodes sleep POSTURE: which way "down" points
        /// relative to the device → back / left-side / right-side. Drift-free, unlike integrated tilt.
        let gravityX: Double
        let gravityY: Double
        let gravityZ: Double
    }

    /// Pure function so it's unit-testable without sensors. Movement features come from the 10 Hz
    /// decimated samples (`s`); the dense envelopes come from the raw 50 Hz magnitudes
    /// (`rawAccelMags`/`rawGyroMags`), downsampled to the envelope rate. Raw buffers may be empty
    /// (e.g. a legacy caller that only feeds 10 Hz) — then the envelope falls back to the 10 Hz path.
    static func computeFeatures(_ s: [MotionSample],
                                rawAccelMags: [Double] = [],
                                rawGyroMags: [Double] = [],
                                rawGravity: [(x: Double, y: Double, z: Double)] = []) -> Features {
        guard !s.isEmpty else {
            return Features(rms: 0, jerkRMS: 0, activityCount: 0, enmoMean: 0, meanTilt: 0,
                            accelEnvelope: [], gyroMean: 0, gravityEnvelope: nil,
                            gravityX: 0, gravityY: 0, gravityZ: 0)
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

        // Dense envelope: downsample the magnitude series to the configured accel-envelope rate.
        // Prefer the RAW 50 Hz stream (captureHz) — the heartbeat needs a fine time grid (a 30 ms
        // grid at 32 Hz resolves beat-to-beat timing; the 10 Hz path's 100 ms grid cannot, which is
        // why setting accelEnvelopeHz>10 against the 10 Hz path was a silent no-op). Falls back to
        // the 10 Hz `mags` only if no raw samples were fed (legacy/test callers). Detrending is left
        // to the offline estimator (same as the audio path), so we keep raw magnitude here.
        let accelEnvelope: [Double]
        let gyroMags: [Double]
        if !rawAccelMags.isEmpty {
            accelEnvelope = downsample(rawAccelMags,
                                       fromHz: SomnyaConfig.captureHz,
                                       toHz: SomnyaConfig.accelEnvelopeHz)
            gyroMags = rawGyroMags
        } else {
            accelEnvelope = downsample(mags,
                                       fromHz: SomnyaConfig.analysisHz,
                                       toHz: SomnyaConfig.accelEnvelopeHz)
            gyroMags = s.map { sqrt($0.rx * $0.rx + $0.ry * $0.ry + $0.rz * $0.rz) }
        }
        let gyroMean = gyroMags.isEmpty ? 0 : gyroMags.reduce(0, +) / Double(gyroMags.count)

        var gravityEnvelope: Data?
        if !rawGravity.isEmpty {
            let axes = [rawGravity.map(\.x), rawGravity.map(\.y), rawGravity.map(\.z)].map {
                downsample($0, fromHz: SomnyaConfig.captureHz, toHz: SomnyaConfig.gravityEnvelopeHz)
            }
            var packed: [Float32] = []
            packed.reserveCapacity(axes[0].count * 3)
            for i in axes[0].indices {
                packed += [Float32(axes[0][i]), Float32(axes[1][i]), Float32(axes[2][i])]
            }
            gravityEnvelope = Data(float32s: packed)
        }

        // Mean gravity vector → posture. Averaging over the window is safe: gravity is ~constant
        // while still, and a posture flip mid-window is rare (and shows up as a posture change).
        let gravityX = s.map(\.gx).reduce(0, +) / Double(s.count)
        let gravityY = s.map(\.gy).reduce(0, +) / Double(s.count)
        let gravityZ = s.map(\.gz).reduce(0, +) / Double(s.count)

        return Features(rms: rms, jerkRMS: jerkRMS, activityCount: activityCount,
                        enmoMean: enmoMean, meanTilt: meanTilt, accelEnvelope: accelEnvelope,
                        gyroMean: gyroMean, gravityEnvelope: gravityEnvelope,
                        gravityX: gravityX, gravityY: gravityY, gravityZ: gravityZ)
    }

    /// Decimate a series from `fromHz` to (approximately) `toHz` by averaging consecutive samples
    /// into bins. Averaging (rather than picking every Nth) is a mild anti-alias and keeps the slow
    /// breathing oscillation intact. If toHz >= fromHz the input is returned unchanged.
    static func downsample(_ xs: [Double], fromHz: Double, toHz: Double) -> [Double] {
        guard !xs.isEmpty, toHz > 0, fromHz > 0, toHz < fromHz else { return xs }
        let factor = fromHz / toHz                     // e.g. 10/8 = 1.25 samples per output
        let outCount = max(1, Int((Double(xs.count) / factor).rounded()))
        var out: [Double] = []
        out.reserveCapacity(outCount)
        for i in 0..<outCount {
            let lo = Int((Double(i) * factor).rounded(.down))
            let hi = min(xs.count, Int((Double(i + 1) * factor).rounded(.down)))
            let bin = xs[lo..<max(lo + 1, hi)]
            out.append(bin.reduce(0, +) / Double(bin.count))
        }
        return out
    }
}
