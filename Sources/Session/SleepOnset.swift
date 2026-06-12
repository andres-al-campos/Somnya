import Foundation

/// When did you fall asleep? — a faithful Swift port of the Python `sleep_onset` analysis
/// (analysis/somnya_analyze/stats.py), kept in sync so the app and the offline tooling agree.
///
/// We have NO brain signal, so we never see "asleep" directly — only the BODY's correlates:
///   1. Sustained stillness — awake-in-bed fidgets (immobilityRunLength resets to 0); sleep = still
///      and STAYS still.
///   2. Regular breathing — awake breathing is irregular (low breathingConfidence); it steadies.
/// The validation that makes "fell asleep" trustworthy is a PERSISTENCE CRITERION from clinical sleep
/// scoring: a moment only counts as durable onset if sleep PERSISTS after it — here, the next
/// `persistMinutes` must stay near-perfectly still (movement in < `persistMovedFraction` of windows).
/// "When did I fall asleep?" means "when did I STOP stirring", not the clinical first-persistent-epoch.
///
/// Result tiers mirror the Python honesty: `.asleep` (validated), `.neverSettled` (genuinely restless),
/// `.noSignal` (stillness-tracking wasn't recorded — older build; don't claim the user never slept).
enum SleepOnset {

    /// Tuning — mirrors the Python constants exactly.
    static let immobilityRun = 8            // windows of unbroken stillness that mark a settling attempt
    static let breathConf = 0.33            // breathingConfidence at/above which the rhythm reads regular
    static let persistMinutes = 10.0        // sleep must persist this long after onset (clinical ~10 min)
    static let persistMovedFraction = 0.05  // ...with movement in < this fraction of post-onset windows

    /// The outcome, carrying enough to render both the stat card and the chart markers.
    enum Result: Equatable {
        /// Durable onset found. `settleMinutes` = headline "fell asleep" time (minutes from start).
        /// `driftMinutes` = an earlier doze that didn't stick (nil when onset stuck first try).
        /// `stirs` = movements before settling. `confidence` 0…1 — how cleanly it resolved.
        case asleep(settleMinutes: Double, driftMinutes: Double?, stirs: Int, confidence: Double)
        /// Settling never persisted — a genuinely restless night, or onset is off the recorded window.
        case neverSettled
        /// immobilityRunLength never incremented (pre-feature recording) — no data, NOT "never slept".
        case noSignal
    }

    /// Analyze sorted-by-time windows. `minutesFromStart` maps each window to elapsed minutes.
    static func analyze(_ windows: [SensorWindow]) -> Result {
        guard !windows.isEmpty else { return .noSignal }
        let mins = minutesFromStart(windows)
        let imm = windows.map { Double($0.immobilityRunLength) }
        let bconf = windows.map { $0.breathingConfidence ?? 0 }
        let moved = windows.map { $0.accelActivityCount >= SomnyaConfig.movementThreshold }
        let n = windows.count

        // The immobility counter never incrementing across the whole night means stillness-tracking
        // wasn't recorded — NOT that the user never lay still. Distinguish "no signal" from "never
        // settled" so the UI can be honest (a missing-data note, not "you never slept").
        if (imm.max() ?? 0) < Double(immobilityRun) { return .noSignal }

        // A settling ATTEMPT: stillness run is long AND breathing reads regular.
        let attempt = (0..<n).map { imm[$0] >= Double(immobilityRun) && bconf[$0] >= breathConf }
        guard attempt.contains(true) else { return .neverSettled }

        let totalMin = mins.last ?? 0
        let persistMin = min(persistMinutes, max(2.0, totalMin / 4))  // shrink for naps, floor 2 min

        // Does sleep hold for persistMin after window i? (movement in < frac of those windows)
        func persists(_ i: Int) -> Bool {
            let endT = mins[i] + persistMin
            var j = i
            while j < n && mins[j] < endT { j += 1 }
            let seg = moved[i..<max(i + 1, j)]
            guard !seg.isEmpty else { return false }
            let frac = Double(seg.filter { $0 }.count) / Double(seg.count)
            return frac < persistMovedFraction
        }

        // SETTLE = first attempt window whose sleep PERSISTS (the validation that earns "fell asleep").
        var settleIdx = attempt.firstIndex(of: true)!  // safe: attempt.contains(true) above
        for i in 0..<n where attempt[i] && persists(i) { settleIdx = i; break }

        // DRIFT = an earlier attempt that did NOT persist (a real-but-failed doze), if well before settle.
        let firstAttempt = attempt.firstIndex(of: true)!
        let driftIdx: Int? = (firstAttempt < settleIdx && mins[settleIdx] - mins[firstAttempt] >= 3)
            ? firstAttempt : nil

        let stirs = moved[0..<max(1, settleIdx)].filter { $0 }.count

        // Confidence: high when calm held immediately and little stirring preceded it; docked for a
        // fitful onset (drift→settle gap) and a restless run-up.
        var conf = 0.75
        if let d = driftIdx {
            let gap = mins[settleIdx] - mins[d]
            conf -= min(0.30, 0.02 * gap)
        }
        conf -= min(0.20, 0.01 * Double(stirs))
        if !(attempt[settleIdx] && persists(settleIdx)) { conf = min(conf, 0.35) }
        conf = max(0.25, min(0.85, conf))

        return .asleep(settleMinutes: mins[settleIdx],
                       driftMinutes: driftIdx.map { mins[$0] },
                       stirs: stirs, confidence: conf)
    }

    /// Elapsed minutes from the first window's start, per window.
    static func minutesFromStart(_ windows: [SensorWindow]) -> [Double] {
        guard let t0 = windows.first?.startTime else { return [] }
        return windows.map { $0.startTime.timeIntervalSince(t0) / 60.0 }
    }
}
