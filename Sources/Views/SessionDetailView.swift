import SwiftUI
import SwiftData
import Charts

/// Per-session readout (the MVP "morning summary"): duration, window count, detection method,
/// and a movement timeline built from the captured SensorWindows. No staging/score yet —
/// that's post-MVP. This proves the captured data is real and inspectable.
struct SessionDetailView: View {
    let session: SleepSession

    private var windows: [SensorWindow] {
        session.windows.sorted { $0.startTime < $1.startTime }
    }

    /// When the user fell asleep (durable onset). Computed once; drives the card and the chart markers.
    private var onset: SleepOnset.Result {
        SleepOnset.analyze(windows)
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
                } else {
                    onsetCard
                    movementChart
                    breathingCard
                    featureSummary
                }
            }
            .padding()
        }
        .navigationTitle(session.startTime.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .background(Color.black.opacity(0.94))
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
                    .annotation(position: .top, alignment: .leading) {
                        Text("almost").font(.caption2).foregroundStyle(Self.driftColor)
                    }
            }
            RuleMark(x: .value("Fell asleep", d.settle))
                .foregroundStyle(Self.settleColor)
                .lineStyle(StrokeStyle(lineWidth: 1.8))
                .annotation(position: .top, alignment: .leading) {
                    Text("fell asleep").font(.caption2).foregroundStyle(Self.settleColor)
                }
        }
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
