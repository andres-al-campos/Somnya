import Foundation

/// The night's measured shape from movement alone: when sleep broke for good, the longest still
/// stretch, and the movements. A port of `wake_time`, `longest_still_min` and `movement_events` in
/// analysis/somnya_analyze/stats.py, kept in step with it so the app and the offline tooling agree.
/// Reads only per-window scalars, so it still works on a night whose raw streams were pruned.
enum NightStats {
    /// Peak activity at or above this is a large movement (roll, sit-up) rather than a twitch:
    /// real nights cluster small ones at 0.6–1.3 with a clear gap to the big ones.
    static let largeMovement = 1.5
    /// The awake tail is looked at for this long to judge how clean the wake was.
    static let wakeActiveMinutes = 8.0

    struct Movement: Equatable {
        let minute: Double
        let large: Bool
    }

    struct Wake: Equatable {
        let minute: Double
        let confidence: Double
    }

    /// Minutes from start of the end of the last sustained-sleep block, or nil when there's no
    /// onset or the quiet runs to the end of the recording (stopped while still asleep).
    static func wake(_ windows: [SensorWindow], settleMinutes: Double) -> Wake? {
        let n = windows.count
        guard n >= 2 else { return nil }
        let mins = SleepOnset.minutesFromStart(windows)
        let act = windows.map(\.accelActivityCount)
        let moved = act.map { $0 >= SomnyaConfig.movementThreshold }
        let total = mins[n - 1]

        // The main sleep block: the longest quiet run starting at or after onset.
        var bestLen = 0.0, bestEnd: Int?
        var i = 0
        while i < n {
            guard !moved[i], mins[i] >= settleMinutes else { i += 1; continue }
            var j = i
            while j + 1 < n && !moved[j + 1] { j += 1 }
            if mins[j] - mins[i] > bestLen { bestLen = mins[j] - mins[i]; bestEnd = j }
            i = j + 1
        }
        guard let end = bestEnd else { return nil }

        // Walk forward to the first break after which quiet doesn't resume for long: a break
        // followed by a long quiet run was an arousal slept off, not the morning.
        let resume = min(20, max(5, total / 6))
        var wakeIdx: Int?
        var k = end + 1
        while k < n {
            if moved[k] {
                var longestAfter = 0.0, m = k
                while m < n {
                    if !moved[m] {
                        var p = m
                        while p + 1 < n && !moved[p + 1] { p += 1 }
                        longestAfter = max(longestAfter, mins[p] - mins[m])
                        m = p + 1
                    } else { m += 1 }
                }
                wakeIdx = k
                if longestAfter < resume { break }
            }
            k += 1
        }
        guard let w = wakeIdx else { return nil }

        let lookEnd = mins.firstIndex { $0 >= mins[w] + wakeActiveMinutes } ?? n
        let peak = lookEnd > w ? act[w..<lookEnd].max() ?? 0 : 0
        var conf = 0.55 + min(0.25, 0.1 * peak)
        conf += min(0.10, 0.05 * (total - mins[w]) / 10)
        return Wake(minute: mins[w], confidence: max(0.3, min(0.9, conf)))
    }

    /// Consecutive moved windows collapse into one movement, placed at its peak.
    static func movements(_ windows: [SensorWindow]) -> [Movement] {
        let mins = SleepOnset.minutesFromStart(windows)
        let act = windows.map(\.accelActivityCount)
        var out: [Movement] = []
        var i = 0
        while i < act.count {
            guard act[i] >= SomnyaConfig.movementThreshold else { i += 1; continue }
            var j = i
            while j + 1 < act.count && act[j + 1] >= SomnyaConfig.movementThreshold { j += 1 }
            let peak = (i...j).max { act[$0] < act[$1] }!
            out.append(Movement(minute: mins[peak], large: act[peak] >= largeMovement))
            i = j + 1
        }
        return out
    }

    /// The longest unbroken still stretch, and the minute it ended.
    static func longestStill(_ windows: [SensorWindow]) -> (minutes: Double, endMinute: Double)? {
        guard let idx = windows.indices.max(by: {
            windows[$0].immobilityRunLength < windows[$1].immobilityRunLength
        }), windows[idx].immobilityRunLength > 0 else { return nil }
        let mins = SleepOnset.minutesFromStart(windows)
        return (Double(windows[idx].immobilityRunLength) * SomnyaConfig.windowSeconds / 60, mins[idx])
    }
}
