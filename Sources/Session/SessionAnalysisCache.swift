import Foundation
import SwiftData

/// A persisted snapshot of a session's derived analyses (sleep onset + heart-rate track), so reopening
/// a finished night is near-instant instead of re-running the whole-night BCG autocorrelation every time.
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

    // MARK: - Encode (analyses → cache)

    /// Build a cache row from freshly computed analyses, stamped with the current version.
    static func from(heartbeat: Heartbeat.Track, onset: SleepOnset.Result) -> SessionAnalysisCache {
        let kind: String
        var settle: Double?, drift: Double?, stirs = 0, conf = 0.0
        switch onset {
        case let .asleep(s, d, st, c): kind = "asleep"; settle = s; drift = d; stirs = st; conf = c
        case .neverSettled:            kind = "neverSettled"
        case .noSignal:                kind = "noSignal"
        }
        return SessionAnalysisCache(
            algoVersion: currentVersion,
            hrMinutes: heartbeat.points.map(\.minute),
            hrBPM: heartbeat.points.map(\.bpm),
            hrConfidence: heartbeat.points.map(\.confidence),
            onsetKind: kind, onsetSettleMinutes: settle, onsetDriftMinutes: drift,
            onsetStirs: stirs, onsetConfidence: conf)
    }

    // MARK: - Decode (cache → analyses)

    var heartbeat: Heartbeat.Track {
        // Defensive: only zip up to the shortest array in case a row was ever written inconsistently.
        let n = min(hrMinutes.count, hrBPM.count, hrConfidence.count)
        let pts = (0..<n).map { Heartbeat.Point(minute: hrMinutes[$0], bpm: hrBPM[$0], confidence: hrConfidence[$0]) }
        return Heartbeat.Track(points: pts)
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
