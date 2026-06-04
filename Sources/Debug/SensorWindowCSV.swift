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
        "breathing_rate_variability", "breathing_confidence",
        "assigned_stage", "assigned_confidence"
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
                optNum(w.breathingConfidence),
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
        let url = tempURL(for: session, suffix: "")
        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// All export files for a session: the feature CSV plus the long-form envelope CSV (when any
    /// window captured an envelope). Returns only files that exist, so the share sheet offers
    /// exactly what's available. Letting the analysis tool re-slice window size lives here: the
    /// envelope is exported long-form (one row per envelope sample) so pandas can regroup it.
    static func writeAllTempFiles(for session: SleepSession) throws -> [URL] {
        var urls = [try writeTempFile(for: session)]
        if let envURL = try writeEnvelopeTempFile(for: session) {
            urls.append(envURL)
        }
        return urls
    }

    /// Long-form envelope CSV: window_start_iso, sample_index, amplitude. nil if no window has an
    /// envelope (e.g. mic was off all session).
    static func writeEnvelopeTempFile(for session: SleepSession) throws -> URL? {
        let iso = ISO8601DateFormatter()
        let sorted = session.windows.sorted { $0.startTime < $1.startTime }
        // raw + filtered side by side so the band-pass before/after is directly comparable.
        var lines = ["window_start_iso,sample_index,amplitude,filtered_amplitude"]
        var any = false
        for w in sorted {
            guard let env = w.audioEnvelope, !env.isEmpty else { continue }
            any = true
            let ts = iso.string(from: w.startTime)
            let filt = w.audioEnvelopeFiltered ?? []
            for (i, v) in env.enumerated() {
                let f = i < filt.count ? num(filt[i]) : ""
                lines.append("\(ts),\(i),\(num(v)),\(f)")
            }
        }
        guard any else { return nil }
        let url = tempURL(for: session, suffix: "-envelope")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Shared temp-file URL builder with a collision-safe, slash/colon-free name.
    private static func tempURL(for session: SleepSession, suffix: String) -> URL {
        let stamp = session.startTime.formatted(.iso8601
            .year().month().day().dateSeparator(.dash)
            .time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        let name = "somnya-session-\(stamp)\(suffix).csv"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
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
