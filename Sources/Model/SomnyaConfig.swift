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
}
