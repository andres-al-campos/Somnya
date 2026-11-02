import Foundation
import SwiftData

/// A persisted snapshot of a session's derived analyses (sleep onset, heart-rate track, and the night's
/// wake, still stretch and movements), so opening a finished night never has to load its windows.
///
/// Past nights never change, so the only honest reason to recompute is an algorithm change — hence
/// `algoVersion`. It combines `Heartbeat.algoVersion` + `SleepOnset.algoVersion`; if either bumps, the
/// stored snapshot is considered stale and the view recomputes (and overwrites) it. The payload is tiny
/// (~a few hundred HR points × 3 Doubles ≈ low-KB), so this trades a sliver of storage for instant reads.
///
/// HR points are stored as three parallel `[Double]` arrays (minute / bpm / confidence) — SwiftData
/// persists `[Double]` natively, the same way `SensorWindow` stores its envelopes. Onset flattens to a
/// discriminator string plus a few optional Doubles/Int, reconstructed back into `SleepOnset.Result`.
@Model
final class SessionAnalysisCache {
    /// Combined algorithm version this snapshot was computed with. Stale if it != `currentVersion`.
    var algoVersion: String

    // Heart-rate track, as parallel arrays (one entry per tracked point).
    var hrMinutes: [Double]
    var hrBPM: [Double]
    var hrConfidence: [Double]

    // Sleep onset, flattened. `onsetKind` ∈ {"asleep","neverSettled","noSignal"}; the rest apply to asleep.
    var onsetKind: String
    var onsetSettleMinutes: Double?
    var onsetDriftMinutes: Double?
    var onsetStirs: Int
    var onsetConfidence: Double

    // The Night screen's movement figures. A row saved before these existed has `hasNightStats` false.
    var hasNightStats: Bool = false
    var wakeMinute: Double?
    var wakeConfidence: Double?
    var longestStillMinutes: Double?
    var longestStillEndMinute: Double?
    var movementMinutes: [Double] = []
    var movementLarge: [Bool] = []

    @Relationship var session: SleepSession?

    init(algoVersion: String,
         hrMinutes: [Double], hrBPM: [Double], hrConfidence: [Double],
         onsetKind: String, onsetSettleMinutes: Double?, onsetDriftMinutes: Double?,
         onsetStirs: Int, onsetConfidence: Double) {
        self.algoVersion = algoVersion
        self.hrMinutes = hrMinutes
        self.hrBPM = hrBPM
        self.hrConfidence = hrConfidence
        self.onsetKind = onsetKind
        self.onsetSettleMinutes = onsetSettleMinutes
        self.onsetDriftMinutes = onsetDriftMinutes
        self.onsetStirs = onsetStirs
        self.onsetConfidence = onsetConfidence
    }

    // MARK: - Version key

    /// The version a fresh computation would carry today. A cache whose `algoVersion` differs is stale.
    static var currentVersion: String { "\(Heartbeat.algoVersion)+\(SleepOnset.algoVersion)" }

    var isStale: Bool { algoVersion != Self.currentVersion }

    /// Holds everything the Night screen reads, so the night's windows can stay unloaded.
    var isComplete: Bool { !isStale && hasNightStats }

    // MARK: - Encode (analyses → cache)

    /// Build a cache row from freshly computed analyses, stamped with the current version.
    static func from(heartbeat: Heartbeat.Track, onset: SleepOnset.Result, windows: [SensorWindow]) -> SessionAnalysisCache {
        let kind: String
        var settle: Double?, drift: Double?, stirs = 0, conf = 0.0
        switch onset {
        case let .asleep(s, d, st, c): kind = "asleep"; settle = s; drift = d; stirs = st; conf = c
        case .neverSettled:            kind = "neverSettled"
        case .noSignal:                kind = "noSignal"
        }
        let cache = SessionAnalysisCache(
            algoVersion: currentVersion,
            hrMinutes: heartbeat.points.map(\.minute),
            hrBPM: heartbeat.points.map(\.bpm),
            hrConfidence: heartbeat.points.map(\.confidence),
            onsetKind: kind, onsetSettleMinutes: settle, onsetDriftMinutes: drift,
            onsetStirs: stirs, onsetConfidence: conf)
        let wake = settle.flatMap { NightStats.wake(windows, settleMinutes: $0) }
        let still = NightStats.longestStill(windows)
        let movements = NightStats.movements(windows)
        cache.hasNightStats = true
        cache.wakeMinute = wake?.minute
        cache.wakeConfidence = wake?.confidence
        cache.longestStillMinutes = still?.minutes
        cache.longestStillEndMinute = still?.endMinute
        cache.movementMinutes = movements.map(\.minute)
        cache.movementLarge = movements.map(\.large)
        return cache
    }

    /// Works out what `session` is missing from its windows, and returns it as a new row attached to
    /// the session, replacing the old one. Heart rate and onset carry over when still fresh, and heart
    /// rate also when a pruned night has nothing left to recompute it from. Not saved or inserted for a
    /// night still recording, which will gain windows.
    static func refresh(_ session: SleepSession, in context: ModelContext) -> SessionAnalysisCache {
        let windows = session.windows.sorted { $0.startTime < $1.startTime }
        let old = session.analysisCache
        let fresh = old.flatMap { $0.isStale ? nil : $0 }
        let heart: Heartbeat.Track
        if let fresh {
            heart = fresh.heartbeat
        } else if windows.contains(where: { $0.heartSegments != nil || $0.hasRawStreams }) {
            heart = Heartbeat.track(of: windows)
        } else {
            heart = old?.heartbeat ?? Heartbeat.Track(points: [])
        }
        let cache = from(heartbeat: heart, onset: fresh?.onset ?? SleepOnset.analyze(windows), windows: windows)
        guard session.endTime != nil else { return cache }
        if let old { context.delete(old) }
        cache.session = session
        session.analysisCache = cache
        context.insert(cache)
        return cache
    }

    // MARK: - Decode (cache → analyses)

    var heartbeat: Heartbeat.Track {
        // Defensive: only zip up to the shortest array in case a row was ever written inconsistently.
        let n = min(hrMinutes.count, hrBPM.count, hrConfidence.count)
        let pts = (0..<n).map { Heartbeat.Point(minute: hrMinutes[$0], bpm: hrBPM[$0], confidence: hrConfidence[$0]) }
        return Heartbeat.Track(points: pts)
    }

    var wake: NightStats.Wake? {
        guard let minute = wakeMinute, let confidence = wakeConfidence else { return nil }
        return NightStats.Wake(minute: minute, confidence: confidence)
    }

    var longestStill: (minutes: Double, endMinute: Double)? {
        guard let minutes = longestStillMinutes, let end = longestStillEndMinute else { return nil }
        return (minutes, end)
    }

    var movements: [NightStats.Movement] {
        zip(movementMinutes, movementLarge).map { NightStats.Movement(minute: $0, large: $1) }
    }

    var onset: SleepOnset.Result {
        switch onsetKind {
        case "asleep":
            return .asleep(settleMinutes: onsetSettleMinutes ?? 0,
                           driftMinutes: onsetDriftMinutes,
                           stirs: onsetStirs, confidence: onsetConfidence)
        case "neverSettled": return .neverSettled
        default:             return .noSignal
        }
    }
}
