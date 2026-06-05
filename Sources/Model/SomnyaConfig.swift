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
    /// PLACEHOLDER — to be replaced by per-night auto-scaled threshold.
    static let movementThreshold: Double = 0.05

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
}
