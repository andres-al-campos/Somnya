import Foundation
import SwiftData

/// Drops the raw sensor streams from nights older than the last `SomnyaConfig.rawRetentionNights`,
/// so the store stops growing a night's worth of envelopes forever.
///
/// Before a night loses its streams, its analysis snapshot is brought up to date while the streams
/// are still there: the heart-rate track can't be recomputed afterwards. Runs on its own context off
/// the main actor, since a backlog of old nights means a heartbeat analysis each.
@ModelActor
actor RawRetention {
    /// Prunes on a context of its own, off the main thread, and logs the outcome. Run at launch and
    /// after each recording ends, so the store never holds more than one night over the limit.
    static func prune(_ container: ModelContainer) async {
        do {
            // Created off the main actor: a model actor runs on the thread that created it, and
            // made from a view it pruned on the main thread, leaving the screen black while it worked.
            let pruned = try await Task.detached { try await RawRetention(modelContainer: container).run() }.value
            if pruned > 0 { SomnyaLog.lifecycle("Dropped raw sensor streams from \(pruned) old nights") }
        } catch {
            SomnyaLog.lifecycle("Pruning raw sensor streams failed; old nights keep them until the next try: \(error)")
        }
    }

    /// Returns how many nights lost their streams.
    func run() throws -> Int {
        let sessions = try modelContext.fetch(
            FetchDescriptor<SleepSession>(sortBy: [SortDescriptor(\.startTime, order: .reverse)]))
        // A night being recorded is writing to the store; leave pruning for when the phone is idle.
        guard !sessions.contains(where: { $0.endTime == nil }) else { return 0 }

        var pruned = 0
        let open = FetchDescriptor<SleepSession>(predicate: #Predicate { $0.endTime == nil })
        for session in sessions.dropFirst(SomnyaConfig.rawRetentionNights) {
            // A backlog takes minutes (each night is a heartbeat analysis), so tracking can start
            // mid-run: stop between nights rather than compete with capture for the store and CPU.
            guard try modelContext.fetchCount(open) == 0 else { break }
            let windows = session.windows.sorted { $0.startTime < $1.startTime }
            guard windows.contains(where: \.hasRawStreams) else { continue }

            if session.analysisCache?.isStale ?? true {
                if let old = session.analysisCache { modelContext.delete(old) }
                let cache = SessionAnalysisCache.from(
                    heartbeat: Heartbeat.track(of: windows), onset: SleepOnset.analyze(windows))
                cache.session = session
                session.analysisCache = cache
                modelContext.insert(cache)
            }
            for w in windows { w.dropRawStreams() }
            // Save per night, so a launch cut short keeps what it finished.
            try modelContext.save()
            pruned += 1
        }
        return pruned
    }
}
