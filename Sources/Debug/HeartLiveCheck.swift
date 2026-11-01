import Foundation
import SwiftData

#if targetEnvironment(simulator)

/// Replays each night's stored envelope through `HeartbeatLive`, window by window as capture feeds
/// it, then through storage and back, and compares the track with a whole-night `Heartbeat.analyze`.
/// Run by launching with `-checkHeartLive`; prints one line per night and a verdict.
enum HeartLiveCheck {
    static let flag = "-checkHeartLive"

    static func run(_ context: ModelContext) {
        let sessions = (try? context.fetch(FetchDescriptor<SleepSession>())) ?? []
        var checked = 0, mismatched = 0
        for session in sessions {
            let windows = session.windows.sorted { $0.startTime < $1.startTime }
            guard windows.contains(where: { $0.accelSamples?.isEmpty == false }) else { continue }
            let whole = Heartbeat.analyze(windows)

            var live = HeartbeatLive()
            var stored = Data()
            let mins = SleepOnset.minutesFromStart(windows)
            for (i, w) in windows.enumerated() {
                // Through the packed form too, so rounding to Float32 is part of what's compared.
                let packed = Data(float32s: (w.accelSamples ?? []).map { Float32($0) })
                stored += Heartbeat.encode(live.append(packed.float32s.map { Double($0) }, minute: mins[i]))
            }
            stored += Heartbeat.encode(live.finish())
            let replayed = Heartbeat.track(Heartbeat.decode(stored))

            let same = whole.points.count == replayed.points.count
                && zip(whole.points, replayed.points).allSatisfy {
                    abs($0.minute - $1.minute) < 0.01 && abs($0.bpm - $1.bpm) < 0.01
                }
            checked += 1
            if !same { mismatched += 1 }
            print("HEARTLIVE \(session.startTime) whole=\(whole.points.count) pts \(whole.medianBPM ?? 0) "
                  + "live=\(replayed.points.count) pts \(replayed.medianBPM ?? 0) \(same ? "same" : "DIFFERENT") "
                  + "stored=\(stored.count) bytes")
        }
        print("HEARTLIVE done: \(checked) nights, \(mismatched) different")
    }
}

#endif
