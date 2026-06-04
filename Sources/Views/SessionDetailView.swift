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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if windows.isEmpty {
                    emptyState
                } else {
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

    private var movementChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Movement over time")
                .font(.headline)
            Text("Accelerometer activity per 30s window — higher = more movement (likely awake/restless).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Chart(windows) { w in
                AreaMark(
                    x: .value("Time", w.startTime),
                    y: .value("Activity", w.accelActivityCount)
                )
                .foregroundStyle(.indigo.opacity(0.6))
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
                Chart(breathingWindows) { w in
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
