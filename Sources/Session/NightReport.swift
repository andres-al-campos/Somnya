import Foundation
import SwiftData

/// Everything the Night screen says about one night, as plain values so it can cross from the
/// actor that computes it to the view. Minutes count from the start of the recording.
struct NightReport: Sendable, Identifiable {
    let id: PersistentIdentifier
    let start: Date
    let inBedMinutes: Double
    /// Durable onset, estimated from stillness (and breathing confidence, which the empty-bed
    /// control showed carries nothing). nil when the night never settled or has no stillness data.
    let settleMinutes: Double?
    let settleConfidence: Double
    let wake: NightStats.Wake?
    let longestStill: (minutes: Double, endMinute: Double)?
    let movements: [NightStats.Movement]
    let heartBPM: Double?
    let heartConfidence: Double?

    /// Asleep from onset to the wake, or to the end of the recording when no wake was found.
    var asleepMinutes: Double? {
        settleMinutes.map { max(0, (wake?.minute ?? inBedMinutes) - $0) }
    }
    var largeMovements: Int { movements.filter(\.large).count }
    /// The asleep figure is only as sure as the less sure of its two ends.
    var asleepConfidence: Double { min(settleConfidence, wake?.confidence ?? settleConfidence) }
}

/// Builds the report for a night and for the nights before it that make up "usual".
@ModelActor
actor NightReporter {
    /// How many earlier nights "usual" averages over.
    static let usualNights = 7
    /// Recordings shorter than this are naps or false starts and would drag "usual" down.
    static let minNightMinutes = 3.0 * 60

    /// The night itself, then up to `usualNights` earlier finished nights, newest first.
    func reports(for id: PersistentIdentifier) throws -> (night: NightReport, before: [NightReport])? {
        guard let session = modelContext.model(for: id) as? SleepSession else { return nil }
        let start = session.startTime
        var earlier = FetchDescriptor<SleepSession>(
            predicate: #Predicate { $0.startTime < start && $0.endTime != nil },
            sortBy: [SortDescriptor(\.startTime, order: .reverse)])
        earlier.fetchLimit = Self.usualNights * 3
        let before = try modelContext.fetch(earlier)
            .filter { $0.duration >= Self.minNightMinutes * 60 }
            .prefix(Self.usualNights)
            .map { report(for: $0, computeHeart: false) }
        return (report(for: session, computeHeart: true), Array(before))
    }

    /// Onset and heart rate come from the session's cache when it's fresh. Heart rate is costly,
    /// so only the night on screen recomputes it; earlier nights without a fresh cache go without.
    private func report(for session: SleepSession, computeHeart: Bool) -> NightReport {
        let windows = session.windows.sorted { $0.startTime < $1.startTime }
        let fresh = session.analysisCache.flatMap { $0.isStale ? nil : $0 }
        let onset = fresh?.onset ?? SleepOnset.analyze(windows)
        var heart = fresh?.heartbeat
        if heart == nil, computeHeart, windows.contains(where: \.hasRawStreams) {
            let track = Heartbeat.analyze(windows)
            heart = track
            if session.endTime != nil {
                if let old = session.analysisCache { modelContext.delete(old) }
                let cache = SessionAnalysisCache.from(heartbeat: track, onset: onset)
                cache.session = session
                session.analysisCache = cache
                modelContext.insert(cache)
                try? modelContext.save()
            }
        }

        var settle: Double?, settleConf = 0.0
        if case let .asleep(s, _, _, c) = onset { settle = s; settleConf = c }
        return NightReport(
            id: session.persistentModelID,
            start: session.startTime,
            inBedMinutes: session.duration / 60,
            settleMinutes: settle,
            settleConfidence: settleConf,
            wake: settle.flatMap { NightStats.wake(windows, settleMinutes: $0) },
            longestStill: NightStats.longestStill(windows),
            movements: NightStats.movements(windows),
            heartBPM: heart?.medianBPM,
            heartConfidence: heart?.meanConfidence)
    }
}
