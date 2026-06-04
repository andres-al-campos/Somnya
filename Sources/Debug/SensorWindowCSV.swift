import Foundation

/// Turns a session's SensorWindows into a CSV — one row per 30s window, every computed feature
/// as a column. Pure string-building so it's testable without UI and works on ANY session,
/// including ones recorded before the audio analyzer existed (those rows just have blank audio
/// columns — the honest truth that no breathing data was captured that night).
///
/// Structured so future per-window arrays (the loudness envelope) or raw audio export attach as
/// SEPARATE files through the same share sheet, not crammed into this row-per-window table.
enum SensorWindowCSV {

    /// Column order is stable so external tools (Numbers, pandas) can rely on it.
    static let header = [
        "start_time_iso", "window_seconds",
        "accel_rms", "accel_jerk_rms", "accel_activity_count", "accel_enmo_mean",
        "immobility_run_length", "tilt_angle", "posture_change_count",
        "audio_rms", "audio_floor", "breathing_rate_bpm",
        "breathing_rate_variability", "assigned_stage", "assigned_confidence"
    ].joined(separator: ",")

    /// Build the full CSV text for a session's windows (sorted by time).
    static func make(from windows: [SensorWindow]) -> String {
        let iso = ISO8601DateFormatter()
        let sorted = windows.sorted { $0.startTime < $1.startTime }
        var lines = [header]
        for w in sorted {
            let row = [
                iso.string(from: w.startTime),
                num(w.windowSeconds),
                num(w.accelRMS),
                num(w.accelJerkRMS),
                num(w.accelActivityCount),
                num(w.accelENMOMean),
                String(w.immobilityRunLength),
                num(w.tiltAngle),
                String(w.postureChangeCount),
                optNum(w.audioRMS),
                optNum(w.audioFloor),
                optNum(w.breathingRate),
                optNum(w.breathingRateVariability),
                w.assignedStageRaw,
                num(w.assignedConfidence)
            ].joined(separator: ",")
            lines.append(row)
        }
        return lines.joined(separator: "\n")
    }

    /// Write the CSV to a temp file and return its URL, for the share sheet. Filename encodes the
    /// session start so multiple exports don't collide.
    static func writeTempFile(for session: SleepSession) throws -> URL {
        let csv = make(from: session.windows)
        let stamp = session.startTime.formatted(.iso8601
            .year().month().day().dateSeparator(.dash)
            .time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        let name = "somnya-session-\(stamp).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Formatting helpers

    /// 6 decimal places — enough precision for the small feature magnitudes without scientific notation.
    private static func num(_ v: Double) -> String {
        String(format: "%.6f", v)
    }

    /// Empty cell for nil (e.g. audio columns on pre-analyzer sessions) — honest blank, not a fake 0.
    private static func optNum(_ v: Double?) -> String {
        guard let v else { return "" }
        return num(v)
    }
}
