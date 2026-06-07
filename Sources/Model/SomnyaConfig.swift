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

    /// Band-pass edges (Hz) applied to audio BEFORE building the envelope. Breathing airflow noise
    /// is low-frequency; birds/hiss/sibilance are high. Isolating this band rejects that noise —
    /// gain can't (it scales noise too). PLACEHOLDER edges — tune against real before/after data.
    static let breathingBandLowHz: Double = 50
    static let breathingBandHighHz: Double = 1000

    // MARK: - Accelerometer breathing (phone-on-mattress)

    /// Rate (Hz) at which the accelerometer magnitude envelope is captured per window, so the same
    /// envelope→autocorrelation breathing estimator can run on bed motion (ballistocardiography-
    /// style) — a silent, emission-free alternative to the mic when the phone rests on the mattress.
    /// Breathing peaks at 0.5 Hz, so 8 Hz is 16x oversampled — ample margin — while also leaving
    /// headroom for the faster heartbeat jolt (~1-2 Hz) if we ever chase that. Storage is ~2x the
    /// audio envelope, negligible against the audio data already stored. "Capture dense, re-slice
    /// forever" — same philosophy as the audio envelope and Mel bands.
    static let accelEnvelopeHz: Double = 8
}
