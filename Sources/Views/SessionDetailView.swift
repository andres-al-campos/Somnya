import SwiftUI
import SwiftData
import Charts

/// Per-session readout (the MVP "morning summary"): duration, window count, detection method,
/// and a movement timeline built from the captured SensorWindows. No staging/score yet —
/// that's post-MVP. This proves the captured data is real and inspectable.
struct SessionDetailView: View {
    let session: SleepSession
    @Environment(\.modelContext) private var modelContext

    /// The heavy analyses (onset + the BCG filtfilt over the whole night) are expensive enough that
    /// running them on every SwiftUI body re-evaluation froze the screen for seconds. They run ONCE per
    /// session in `.task` and the rendered view reads this bundle. Better still, the result is PERSISTED
    /// to SwiftData (`SessionAnalysisCache`), so reopening a finished night skips the compute entirely.
    /// `nil` = still loading (we show a spinner); empty results render their honest "no data" states.
    private struct Analysis {
        let onset: SleepOnset.Result
        let heartbeat: Heartbeat.Track
    }
    @State private var analysis: Analysis?

    private var windows: [SensorWindow] {
        session.windows.sorted { $0.startTime < $1.startTime }
    }

    /// When the user fell asleep (durable onset) — from the cached bundle once ready.
    private var onset: SleepOnset.Result {
        analysis?.onset ?? .noSignal
    }

    /// Heart-rate track (accel BCG), two-pass harmonic-rejecting tracker — from the cached bundle.
    private var heartbeat: Heartbeat.Track {
        analysis?.heartbeat ?? Heartbeat.Track(points: [])
    }

    /// HR track points carrying an absolute time, for the chart's time axis.
    private var heartbeatPoints: [(time: Date, bpm: Double, confidence: Double)] {
        guard let t0 = windows.first?.startTime else { return [] }
        return heartbeat.points.map {
            (t0.addingTimeInterval($0.minute * 60), $0.bpm, $0.confidence)
        }
    }

    /// A tight y-range fitted to the actual BPM spread (not the full 40–120 detector band, which left
    /// most of the chart empty and squashed the real variation). Pads ~6 bpm each side for breathing
    /// room and rounds to a clean step; falls back to the detector band when there's no data.
    private var heartbeatYDomain: ClosedRange<Double> {
        let bpms = heartbeat.points.map(\.bpm)
        guard let lo = bpms.min(), let hi = bpms.max() else {
            return Heartbeat.minBPM...Heartbeat.maxBPM
        }
        let pad = 6.0
        let low = max(Heartbeat.minBPM, (lo - pad / 2).rounded(.down))
        let high = min(Heartbeat.maxBPM, (hi + pad).rounded(.up))
        // Guarantee a sane minimum span so a flat night still reads on a sensible scale.
        return low < high - 8 ? low...high : low...(low + 16)
    }

    /// The "fell asleep" / "almost" times as Dates, for placing RuleMarks on the time-axis charts.
    private var onsetDates: (settle: Date, drift: Date?)? {
        guard case let .asleep(settleMin, driftMin, _, _) = onset,
              let t0 = windows.first?.startTime else { return nil }
        let settle = t0.addingTimeInterval(settleMin * 60)
        let drift = driftMin.map { t0.addingTimeInterval($0 * 60) }
        return (settle, drift)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                NavigationLink {
                    RawDataView(session: session)
                } label: {
                    Label("Raw Data (\(windows.count) windows)", systemImage: "tablecells")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }
                .tint(.white)

                if windows.isEmpty {
                    emptyState
                } else if analysis == nil {
                    analyzingState
                } else {
                    onsetCard
                    movementChart
                    breathingCard
                    heartbeatCard
                    featureSummary
                }
            }
            .padding()
        }
        .navigationTitle(session.startTime.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .background(Color.black.opacity(0.94))
        .task(id: session.id) {
            guard !windows.isEmpty, analysis == nil else { return }

            // 1. Fast path — a fresh persisted snapshot means we never touch the autocorrelation.
            if let cache = session.analysisCache, !cache.isStale {
                analysis = Analysis(onset: cache.onset, heartbeat: cache.heartbeat)
                return
            }

            // 2. Slow path — compute once. We deliberately stay on the main actor: SensorWindow is a
            // SwiftData @Model bound to its ModelContext's thread and isn't Sendable, so touching it
            // off-main would be a data race. A yield first lets the spinner paint before the work.
            await Task.yield()
            let snapshot = windows
            let onset = SleepOnset.analyze(snapshot)
            let heartbeat = Heartbeat.analyze(snapshot)
            analysis = Analysis(onset: onset, heartbeat: heartbeat)

            // 3. Persist for instant reopens — but only for FINISHED sessions. An active session will
            // gain more windows, which would silently invalidate a stored snapshot; recompute those.
            guard session.endTime != nil else { return }
            persistAnalysis(heartbeat: heartbeat, onset: onset)
        }
    }

    /// Store the computed analyses on the session so the next open is instant. Replaces any stale
    /// snapshot. Failures here are non-fatal — worst case we just recompute next time, so we log and
    /// move on rather than disturbing the view.
    private func persistAnalysis(heartbeat: Heartbeat.Track, onset: SleepOnset.Result) {
        if let old = session.analysisCache {
            modelContext.delete(old)  // cascade-owned; replace rather than mutate-in-place
        }
        let cache = SessionAnalysisCache.from(heartbeat: heartbeat, onset: onset)
        cache.session = session
        session.analysisCache = cache
        modelContext.insert(cache)
        do {
            try modelContext.save()
        } catch {
            SomnyaLog.lifecycle("Analysis cache save failed (will recompute next open): \(error)")
        }
    }

    private var analyzingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Analyzing the night…")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            stat("Duration", durationString)
            stat("Windows recorded", "\(windows.count)")
            stat("Detection", session.detectionMethod.rawValue.capitalized)
            if let end = session.endTime {
                stat("Ended", end.formatted(date: .omitted, time: .shortened))
            } else {
                stat("Status", "still active")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    // Onset marker palette — shared by the card and the chart RuleMarks so they read as one story.
    private static let settleColor = Color(red: 0.118, green: 0.537, blue: 0.286)  // green "fell asleep"
    private static let driftColor = Color(red: 0.902, green: 0.494, blue: 0.133)   // orange "almost"

    @ViewBuilder
    private var onsetCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Time to fall asleep")
                .font(.headline)
            switch onset {
            case let .asleep(settleMin, driftMin, stirs, confidence):
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(settleMin.rounded())) min")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(Self.settleColor)
                    Text("to fall asleep")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let d = driftMin {
                    Text("Almost dozed off around \(Int(d.rounded())) min, but kept stirring and couldn't stay down until ~\(Int(settleMin.rounded())) min.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Settled and stopped stirring fairly quickly.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                stat("Stirs before settling", "\(stirs)")
                stat("Confidence", "\(Int((confidence * 100).rounded()))%")
                Text("Estimated from when your body stopped stirring and breathing steadied — not a brain-onset measurement, so it's a rough ± a few minutes.")
                    .font(.caption2).foregroundStyle(.secondary)
            case .neverSettled:
                Text("No clear point where you settled into sustained sleep — a restless night, or sleep began after the recording ended.")
                    .font(.callout).foregroundStyle(.secondary)
            case .noSignal:
                Text("Stillness-tracking wasn't recorded this night (older build). Record a night on the current build to see when you fell asleep.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    /// The green "fell asleep" (and orange "almost") RuleMarks, overlaid on any time-axis chart so the
    /// onset story threads through movement + breathing — same single source of truth as the card.
    @ChartContentBuilder
    private var onsetMarkers: some ChartContent {
        if let d = onsetDates {
            if let drift = d.drift {
                RuleMark(x: .value("Almost asleep", drift))
                    .foregroundStyle(Self.driftColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 2,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        onsetLabel("almost", Self.driftColor)
                    }
            }
            RuleMark(x: .value("Fell asleep", d.settle))
                .foregroundStyle(Self.settleColor)
                .lineStyle(StrokeStyle(lineWidth: 1.8))
                .annotation(position: .top, alignment: .leading, spacing: 2,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                    onsetLabel("fell asleep", Self.settleColor)
                }
        }
    }

    /// A small pill-backed marker label. The background keeps it legible where it sits just above the
    /// plot, and `position: .top` with a tight `spacing` keeps it from colliding with the card's
    /// description text above the chart.
    private func onsetLabel(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.black.opacity(0.55), in: Capsule())
    }

    private var movementChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Movement over time")
                .font(.headline)
            Text("Accelerometer activity per 30s window — higher = more movement (likely awake/restless).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Chart {
                ForEach(windows) { w in
                    AreaMark(
                        x: .value("Time", w.startTime),
                        y: .value("Activity", w.accelActivityCount)
                    )
                    .foregroundStyle(.indigo.opacity(0.6))
                }
                onsetMarkers
            }
            .frame(height: 160)
            .padding(.top, 14)  // headroom so the onset label sits above the plot, not over the caption
        }
        .padding()
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Windows that have a trustworthy breathing estimate (nil ones are gaps — too quiet/noisy).
    private var breathingWindows: [SensorWindow] {
        windows.filter { $0.breathingRate != nil }
    }

    @ViewBuilder
    private var breathingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Breathing rate over time")
                .font(.headline)
            if breathingWindows.isEmpty {
                Text("No trustworthy breathing estimate this session. The mic may have been off, the room too quiet, or background noise masked the rhythm. Grant mic access and place the phone near you on the mattress.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Estimated breaths per minute per 30s window (from the mic loudness envelope). Gaps = windows with no clear rhythm.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Chart {
                    ForEach(breathingWindows) { w in
                        LineMark(
                            x: .value("Time", w.startTime),
                            y: .value("Breaths/min", w.breathingRate ?? 0)
                        )
                        .foregroundStyle(.teal)
                        PointMark(
                            x: .value("Time", w.startTime),
                            y: .value("Breaths/min", w.breathingRate ?? 0)
                        )
                        .foregroundStyle(.teal.opacity(0.5))
                        .symbolSize(8)
                    }
                    onsetMarkers
                }
                .frame(height: 160)
                .padding(.top, 14)

                let rates = breathingWindows.compactMap(\.breathingRate)
                let avg = rates.reduce(0, +) / Double(rates.count)
                stat("Avg breathing rate", String(format: "%.1f brpm", avg))
                stat("Windows with breathing", "\(breathingWindows.count) / \(windows.count)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var heartbeatCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Heart rate over time")
                .font(.headline)
            let pts = heartbeatPoints
            if pts.isEmpty {
                Text("No heart-rate track this session. The accelerometer pulse (ballistocardiography) needs the body well-coupled to the mattress and a 32 Hz recording — older nights or poor coupling read nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Resting heart rate from the accelerometer (BCG). Color = confidence; gaps = windows with no clear pulse.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Chart {
                    ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                        PointMark(
                            x: .value("Time", p.time),
                            y: .value("BPM", p.bpm)
                        )
                        .foregroundStyle(by: .value("Confidence", p.confidence))
                        .symbolSize(18)
                    }
                    onsetMarkers
                }
                .chartForegroundStyleScale(range: Gradient(colors: [.orange, .yellow, .green]))
                .chartYScale(domain: heartbeatYDomain)
                .frame(height: 160)
                .padding(.top, 14)

                if let med = heartbeat.medianBPM {
                    stat("Resting heart rate", String(format: "≈ %.0f bpm", med))
                }
                stat("Windows tracked", "\(pts.count) / \(windows.count)")
                Text("Estimated, not a medical reading — the pulse is a faint mechanical vibration through the mattress, so it's only read on the fraction of the night that coupled well.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private var featureSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Window features (averages)")
                .font(.headline)
            let avgRMS = windows.map(\.accelRMS).reduce(0, +) / Double(windows.count)
            let avgJerk = windows.map(\.accelJerkRMS).reduce(0, +) / Double(windows.count)
            let avgCount = windows.map(\.accelActivityCount).reduce(0, +) / Double(windows.count)
            let stillWindows = windows.filter { $0.accelActivityCount < SomnyaConfig.movementThreshold }.count
            stat("Avg RMS", String(format: "%.4f", avgRMS))
            stat("Avg jerk RMS", String(format: "%.4f", avgJerk))
            stat("Avg activity count", String(format: "%.4f", avgCount))
            stat("Still windows", "\(stillWindows) / \(windows.count)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.slash").font(.largeTitle).foregroundStyle(.secondary)
            Text("No sensor windows recorded")
                .font(.headline)
            Text("This session ended before a full 30s window completed, or motion capture wasn't running. Check Debug Logs → capture.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.subheadline)
    }

    private var durationString: String {
        let s = Int(session.duration)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? "\(h)h \(m)m \(sec)s" : "\(m)m \(sec)s"
    }
}
