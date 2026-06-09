import Foundation

/// Single home for all tunable parameters (per spec + user preference for configurable
/// systems over hardcoded values). Movement thresholds here are PLACEHOLDER defaults — the
/// research calls for auto-scaling them per night rather than fixed constants. That
/// per-night calibration is a later task; until then these are sane starting values, kept
/// in one place so nothing magic is buried in the pipeline.
enum SomnyaConfig {
    /// Window length for sensor aggregation.
    static let windowSeconds: Double = 30

    /// Motion capture / analysis rates.
    static let captureHz: Double = 50
    static let analysisHz: Double = 10

    /// Activity-count below which a window is considered "still" (immobility-run accrual).
    /// CALIBRATED against real nap data (June 2026): the quiet/asleep baseline sits at activity
    /// ~0.30–0.45 (median 0.36), while genuine movement events jump to >1.0 (p95 ≈ 4.5). There's a
    /// clean valley around 0.6 separating them. The old 0.05 was far below the noise floor — NO
    /// window ever cleared it, so immobility_run_length was stuck at 0 (a real bug). 0.6 puts the
    /// still baseline below threshold and movement spikes above it. Still a per-device constant for
    /// now; per-night auto-scaling (subtract each night's own baseline) is the eventual refinement.
    static let movementThreshold: Double = 0.6

    /// Tilt change (radians) between windows that counts as a posture change.
    static let postureChangeRadians: Double = 0.35  // ~20°

    /// Day boundary hour for grouping sessions into a SleepDay (default 6pm).
    static let dayBoundaryHour: Int = 18

    // MARK: - Audio / breathing

    /// Rate (Hz) at which the audio envelope is sampled for breathing analysis. Breathing is a
    /// slow rhythm (~4-6s/cycle), so even 4 Hz gives ~20+ samples per breath — well above what's
    /// needed. An offline polling sweep on real nap data showed dropping 10 Hz → 2 Hz barely
    /// changed detection, so 4 Hz halves storage with near-zero accuracy loss. Track only what's
    /// needed. (Raise back toward 10 Hz only if sub-breath shape ever matters.)
    static let audioEnvelopeHz: Double = 4

    /// Plausible human breathing band, in breaths per minute. Anything outside this is rejected
    /// as noise rather than reported as a (wrong) rate. ~6 brpm (deep slow) to ~30 brpm (light/awake).
    static let breathingMinBPM: Double = 6
    static let breathingMaxBPM: Double = 30

    /// Minimum normalized autocorrelation peak height for a breathing estimate to be trusted.
    /// Below this the envelope has no clear periodicity (too noisy/quiet) and we report nil
    /// rather than a fabricated rate. PLACEHOLDER — tune against real overnight envelopes.
    static let breathingMinConfidence: Double = 0.3

    /// Exponential-smoothing factor for the rolling noise floor (per audio buffer). Small =
    /// slow to adapt (tracks the quiet baseline, ignores transient sounds).
    static let noiseFloorSmoothing: Double = 0.02

    // MARK: - Sound-level calibration (dB-SPL)

    /// Offset that converts our raw mic level into real-world decibels (dB-SPL):
    ///   dB_SPL = 20·log10(audio_rms) + splOffset
    /// `audio_rms` is uncalibrated electrical amplitude — proportional to loudness but with no anchor
    /// to the real world. This offset IS that anchor. Two sources, in priority order:
    ///
    ///   1. USER CALIBRATION (best): measured once via the in-app screen against a reference SPL meter,
    ///      stored in UserDefaults. Captures THIS phone through THIS app's AGC path. Overrides the
    ///      default when present.
    ///   2. NOMINAL DEFAULT (`nominalSPLOffsetDB`): a built-in fallback so dB works with zero setup.
    ///      Justified by research: MEMS mic sensitivity ≈ −26 dBFS at 94 dB-SPL → offset ≈ 94−(−26) =
    ///      120 dB, and iOS mics are matched within ~±1–3 dB across units (NIOSH validated one nominal
    ///      value to ±2 dBA on the built-in mic). So the default lands within a few dB on any iPhone.
    ///
    /// Either way the dB is ESTIMATED, not a precision instrument — more so for us because we run AGC
    /// ON (mode .default, so quiet breathing rises), which drifts the gain off the fixed −26 dBFS
    /// assumption. We never claim certified dB; we show an honest approximate scale.
    ///
    /// Nominal value: 94 dB-SPL reference − (−26 dBFS typical MEMS sensitivity) = 120 dB. PLACEHOLDER
    /// for a per-model table later; one constant is within a few dB across iPhones today.
    static let nominalSPLOffsetDB: Double = 120

    private static let splOffsetKey = "somnya.splOffsetDB"

    /// The user's measured offset, or nil if they haven't calibrated. Set by the calibration screen.
    static var userSPLOffsetDB: Double? {
        get {
            // UserDefaults returns 0.0 for a missing key, so guard on presence explicitly.
            guard UserDefaults.standard.object(forKey: splOffsetKey) != nil else { return nil }
            return UserDefaults.standard.double(forKey: splOffsetKey)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: splOffsetKey)
            } else {
                UserDefaults.standard.removeObject(forKey: splOffsetKey)
            }
        }
    }

    /// The offset actually used: the user's calibration if present, else the nominal default.
    /// Always non-nil — dB-SPL is available out of the box, refined by calibration.
    static var splOffsetDB: Double { userSPLOffsetDB ?? nominalSPLOffsetDB }

    /// True when the offset in use was measured by the user (exact-ish), false when it's the nominal
    /// default (approximate). Drives honest labeling: "calibrated" vs "approximate".
    static var isSPLCalibrated: Bool { userSPLOffsetDB != nil }

    /// Convert a raw mic RMS level to dBFS (decibels below full-scale; always ≤ 0).
    /// Pure/unit-testable; `floorDB` clamps silence so log stays finite.
    static func dbFS(fromRMS rms: Double, floorDB: Double = -120) -> Double {
        guard rms > 0 else { return floorDB }
        return max(floorDB, 20 * log10(rms))
    }

    /// Convert a raw mic RMS level to dB-SPL. Always available (nominal default if uncalibrated);
    /// pair with `isSPLCalibrated` to label it exact vs approximate.
    static func dbSPL(fromRMS rms: Double) -> Double {
        dbFS(fromRMS: rms) + splOffsetDB
    }

    /// Band-pass edges (Hz) applied to audio BEFORE building the envelope. Breathing airflow noise
    /// is low-frequency; birds/hiss/sibilance are high. Isolating this band rejects that noise —
    /// gain can't (it scales noise too). PLACEHOLDER edges — tune against real before/after data.
    static let breathingBandLowHz: Double = 50
    static let breathingBandHighHz: Double = 1000

    // MARK: - Accelerometer breathing (phone-on-mattress)

    /// Rate (Hz) at which the accelerometer magnitude envelope is captured per window, so the same
    /// envelope→autocorrelation estimator can run on bed motion (ballistocardiography) — a silent,
    /// emission-free alternative to the mic when the phone rests on the mattress.
    ///
    /// RAISED 8 → 32 Hz (June 2026) after 8 Hz BCG first cleared the heartbeat trust bar on a real
    /// 5-hour night (69 bpm, 33 windows ≥ 0.40 conf, stable across window sizes). Two reasons to go
    /// finer:
    ///   1. RATE accuracy — at 8 Hz the autocorrelation lag grid is coarse in the 40-120 bpm band,
    ///      so the rate quantizes (the std≈20 bpm scatter we saw). 32 Hz sharpens the peak.
    ///   2. HRV — the real "how restful was your sleep" signal is beat-to-beat interval VARIATION,
    ///      ~20-50 ms differences. At 8 Hz each sample is 125 ms apart — you literally cannot
    ///      resolve a 30 ms change on a 125 ms grid. 32 Hz gives a ~31 ms grid — finally finer than
    ///      the variation we're trying to measure. HRV is impossible below this.
    /// Breathing (0.5 Hz) is still wildly oversampled, so the breathing path is unaffected.
    ///
    /// COST: ~4x this stream's bytes (it's ~32% of the export, so the file grows toward ~20 MB/night).
    /// Accepted deliberately: "capture dense" while validating. The raw envelopes are TRANSIENT —
    /// the plan is to prune them after analysis + charts, archiving only the derived insights
    /// (heart/breathing rate, confidence, stats) which are ~25x smaller (<1 MB/night). Pruning is
    /// deferred until the SwiftUI app that owns the archive format exists.
    static let accelEnvelopeHz: Double = 32
}
