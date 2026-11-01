import Foundation
import SwiftData
import SQLite3

/// Which old night cleanup is on, for the main screen.
struct OldNightProgress: Equatable, Sendable {
    let night: Int
    let nights: Int
}

/// Drops the raw sensor streams from nights older than the last `SomnyaConfig.rawRetentionNights`,
/// so the store stops growing a night's worth of envelopes forever.
///
/// Before a night loses its streams, its analysis snapshot is brought up to date while the streams
/// are still there: the heart-rate track can't be recomputed afterwards. Runs on its own context off
/// the main actor, since a backlog of old nights means a heartbeat analysis each.
@ModelActor
actor RawRetention {
    /// Prunes on a context of its own, off the main thread, and logs the outcome. Run at launch.
    /// `onWork` fires when there turns out to be something to clean, so most launches show nothing:
    /// with the night it's on, or nil once it's on the freed space, which isn't counted in nights.
    static func prune(_ container: ModelContainer, onWork: @escaping @Sendable (OldNightProgress?) -> Void) async {
        do {
            // Created off the main actor: a model actor runs on the thread that created it, and
            // made from a view it pruned on the main thread, leaving the screen black while it worked.
            let pruned = try await Task.detached {
                try await RawRetention(modelContainer: container).run(onWork: onWork)
            }.value
            if pruned > 0 { SomnyaLog.lifecycle("Dropped raw sensor streams from \(pruned) old nights") }
        } catch {
            SomnyaLog.lifecycle("Pruning raw sensor streams failed; old nights keep them until the next try: \(error)")
        }
    }

    /// Returns how many nights lost their streams.
    func run(onWork: @Sendable (OldNightProgress?) -> Void) throws -> Int {
        let sessions = try modelContext.fetch(
            FetchDescriptor<SleepSession>(sortBy: [SortDescriptor(\.startTime, order: .reverse)]))
        // A night being recorded is writing to the store; leave pruning for when the phone is idle.
        // Once this has begun a Start waits for it (SessionManager.requestStart).
        guard !sessions.contains(where: { $0.endTime == nil }) else { return 0 }

        var pruned = 0
        let pending = try sessions.dropFirst(SomnyaConfig.rawRetentionNights).filter(holdsRawStreams)
        if !pending.isEmpty { SomnyaLog.lifecycle("\(pending.count) old nights to clean up") }
        for session in pending {
            onWork(OldNightProgress(night: pruned + 1, nights: pending.count))
            let windows = session.windows.sorted { $0.startTime < $1.startTime }

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
        reclaimFreeSpace(onWork: onWork)
        return pruned
    }

    /// Looks at one window, since a night's streams are dropped all at once. `session.windows` would
    /// load every old night's streams to count a backlog, and asking the store whether any window
    /// has a stream was still counting after 37 s, on a question asked at every launch.
    private func holdsRawStreams(_ session: SleepSession) throws -> Bool {
        let id = session.persistentModelID
        var one = FetchDescriptor<SensorWindow>(predicate: #Predicate { $0.session?.persistentModelID == id })
        one.fetchLimit = 1
        return try modelContext.fetch(one).first?.hasRawStreams ?? false
    }

    /// Pages handed back per step: ~4 MB, a fraction of a second, so a main-thread save that has
    /// to wait for one waits that long and no longer.
    static let reclaimPagesPerStep = 1000

    /// Gives the space the dropped streams freed back to the phone. The store reclaims free pages
    /// on its own, but inside whichever save comes next, the main thread's too: with ~600 MB free
    /// that froze launch for 7 s and made Start hang. Doing it here, a step at a time on a
    /// connection of its own, leaves those saves nothing to do.
    private func reclaimFreeSpace(onWork: @Sendable (OldNightProgress?) -> Void) {
        guard let url = modelContainer.configurations.first?.url else { return }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            SomnyaLog.persist("Couldn't open the store to give back freed space: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        sqlite3_busy_timeout(db, 2000)
        let start = freePages(db)
        if start > 0 { onWork(nil) }
        var free = start
        while free > 0 {
            guard sqlite3_exec(db, "PRAGMA incremental_vacuum(\(Self.reclaimPagesPerStep))", nil, nil, nil) == SQLITE_OK else {
                SomnyaLog.persist("Giving back freed space stopped: \(String(cString: sqlite3_errmsg(db)))")
                break
            }
            let now = freePages(db)
            guard now < free else {
                SomnyaLog.persist("Giving back freed space made no progress at \(now) free pages")
                break
            }
            free = now
        }
        if start > 0 {
            SomnyaLog.persist("Gave back \((start - free) * 4096 / 1_048_576) MB of freed space; \(free * 4096 / 1_048_576) MB still free in the store")
        }
    }

    private func freePages(_ db: OpaquePointer?) -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA freelist_count", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }
}
