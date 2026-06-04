import SwiftUI
import SwiftData

/// The "see the actual spreadsheet" view: every SensorWindow as a row, every feature as a column.
/// Horizontally + vertically scrollable so all columns are reachable on a phone. Plus a CSV
/// export (share sheet) to pull the night onto a Mac for real analysis. Works on any session —
/// pre-audio-analyzer rows simply show "—" in the audio columns (no data was captured then).
struct RawDataView: View {
    let session: SleepSession

    @State private var exportItem: ExportFile?
    @State private var exportError: String?

    /// Wrapper so `sheet(item:)` can drive presentation off the payload itself — this avoids the
    /// empty-panel race where `isPresented=true` fires before state is committed. Carries the
    /// feature CSV plus (when present) the envelope CSV, both handed to the share sheet at once.
    private struct ExportFile: Identifiable {
        let id = UUID()
        let urls: [URL]
    }

    private var windows: [SensorWindow] {
        session.windows.sorted { $0.startTime < $1.startTime }
    }

    private let columns: [(String, (SensorWindow) -> String)] = [
        ("time",      { $0.startTime.formatted(date: .omitted, time: .standard) }),
        ("secs",      { fmt($0.windowSeconds, 0) }),
        ("accelRMS",  { fmt($0.accelRMS) }),
        ("jerk",      { fmt($0.accelJerkRMS) }),
        ("activity",  { fmt($0.accelActivityCount) }),
        ("ENMO",      { fmt($0.accelENMOMean) }),
        ("immob",     { String($0.immobilityRunLength) }),
        ("tilt",      { fmt($0.tiltAngle) }),
        ("postureΔ",  { String($0.postureChangeCount) }),
        ("audioRMS",  { optFmt($0.audioRMS) }),
        ("floor",     { optFmt($0.audioFloor) }),
        ("breath",    { optFmt($0.breathingRate, 1) }),
        ("breathVar", { optFmt($0.breathingRateVariability, 1) }),
    ]

    var body: some View {
        Group {
            if windows.isEmpty {
                ContentUnavailableView("No windows recorded",
                                       systemImage: "tablecells",
                                       description: Text("This session captured no 30s windows."))
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow {
                            ForEach(columns, id: \.0) { col in
                                Text(col.0)
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Divider().gridCellColumns(columns.count)
                        ForEach(windows) { w in
                            GridRow {
                                ForEach(columns, id: \.0) { col in
                                    Text(col.1(w))
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Raw Data (\(windows.count))")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color.black.opacity(0.94))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    exportCSV()
                } label: {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                }
                .disabled(windows.isEmpty)
            }
        }
        .sheet(item: $exportItem) { item in
            ShareSheet(items: item.urls)
        }
        .alert("Export failed", isPresented: .constant(exportError != nil)) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private func exportCSV() {
        do {
            let urls = try SensorWindowCSV.writeAllTempFiles(for: session)
            exportItem = ExportFile(urls: urls)
        } catch {
            // What went wrong + how to recover.
            exportError = "Couldn't write the CSV file: \(error.localizedDescription). Free up storage and try again, or restart the app."
        }
    }
}

// MARK: - Cell formatting

private func fmt(_ v: Double, _ places: Int = 4) -> String {
    String(format: "%.\(places)f", v)
}

private func optFmt(_ v: Double?, _ places: Int = 4) -> String {
    guard let v else { return "—" }
    return String(format: "%.\(places)f", v)
}
