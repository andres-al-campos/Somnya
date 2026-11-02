import Foundation
import SwiftData
import SQLite3

/// Saves each finished night's results, so the Night screen never waits on them, and drops the raw
/// sensor streams from nights older than the last `SomnyaConfig.rawRetentionNights`, so the store
/// stops growing a night's worth of envelopes forever.
///
/// Results are saved first, while the streams are still there: the heart-rate track can't be
/// recomputed afterwards. Runs on its own context off the main actor, since a backlog of old nights
/// means a heartbeat analysis each.
@ModelActor
actor RawRetention {
    /// Prunes on a context of its own, off the main thread, and logs the outcome.
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
        for (index, session) in sessions.enumerated() {
            // A backlog takes minutes (each night is a heartbeat analysis), so tracking can start
            // mid-run: stop between nights rather than compete with capture for the store and CPU.
            guard try modelContext.fetchCount(open) == 0 else { break }
            if session.analysisCache?.isComplete != true {
                _ = SessionAnalysisCache.refresh(session, in: modelContext)
                try modelContext.save()
            }
            guard index >= SomnyaConfig.rawRetentionNights else { continue }
            let windows = session.windows
            guard windows.contains(where: \.hasRawStreams) else { continue }

            for w in windows { w.dropRawStreams() }
            // Save per night, so a launch cut short keeps what it finished.
            try modelContext.save()
            pruned += 1
            // After each night, not at the end: free pages left waiting would land on the save that
            // starts a session tapped mid-run.
            try reclaimFreeSpace()
        }
        try reclaimFreeSpace()
        return pruned
    }

    /// Pages handed back per step: ~4 MB, a fraction of a second, so a save that has to wait for
    /// one (starting a night) waits that long and no longer.
    static let reclaimPagesPerStep = 1000

    /// Gives the space the dropped streams freed back to the phone. The store reclaims free pages
    /// on its own, but inside whichever save comes next, the main thread's too: with ~600 MB free
    /// that froze launch for 7 s and made Start hang. Doing it here, a step at a time on a
    /// connection of its own, leaves those saves nothing to do. Stops if a night starts recording.
    private func reclaimFreeSpace() throws {
        guard let url = modelContainer.configurations.first?.url else { return }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            SomnyaLog.persist("Couldn't open the store to give back freed space: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        sqlite3_busy_timeout(db, 2000)
        let open = FetchDescriptor<SleepSession>(predicate: #Predicate { $0.endTime == nil })
        let start = freePages(db)
        var free = start
        while free > 0 {
            guard try modelContext.fetchCount(open) == 0 else { break }
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
