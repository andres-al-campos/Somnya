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

    /// The night itself, then up to `usualNights` earlier finished nights, newest first. Earlier nights
    /// whose results aren't saved yet are left out rather than worked out here: cleanup fills them in.
    func reports(for id: PersistentIdentifier) throws -> (night: NightReport, before: [NightReport])? {
        let began = Date()
        defer { SomnyaLog.lifecycle("Night report took \(Int(Date().timeIntervalSince(began) * 1000)) ms") }
        guard let session = modelContext.model(for: id) as? SleepSession else { return nil }
        let start = session.startTime
        var earlier = FetchDescriptor<SleepSession>(
            predicate: #Predicate { $0.startTime < start && $0.endTime != nil },
            sortBy: [SortDescriptor(\.startTime, order: .reverse)])
        earlier.fetchLimit = Self.usualNights * 3
        let before = try modelContext.fetch(earlier)
            .filter { $0.duration >= Self.minNightMinutes * 60 }
            .compactMap { s in s.analysisCache.flatMap { $0.isComplete ? report(for: s, from: $0) : nil } }
            .prefix(Self.usualNights)

        var cache = session.analysisCache
        if cache?.isComplete != true {
            cache = SessionAnalysisCache.refresh(session, in: modelContext)
            try? modelContext.save()
        }
        return (report(for: session, from: cache!), Array(before))
    }

    /// Reads only the saved results. Loading a night's windows brings its raw streams too, 25 MB a
    /// night, and with eight nights that held this screen for seconds to read a few numbers.
    private func report(for session: SleepSession, from cache: SessionAnalysisCache) -> NightReport {
        var settle: Double?, settleConf = 0.0
        if case let .asleep(s, _, _, c) = cache.onset { settle = s; settleConf = c }
        let heart = cache.heartbeat
        return NightReport(
            id: session.persistentModelID,
            start: session.startTime,
            inBedMinutes: session.duration / 60,
            settleMinutes: settle,
            settleConfidence: settleConf,
            wake: cache.wake,
            longestStill: cache.longestStill,
            movements: cache.movements,
            heartBPM: heart.medianBPM,
            heartConfidence: heart.meanConfidence)
    }
}
