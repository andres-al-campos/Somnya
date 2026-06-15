import Foundation

/// Exports a full session as ONE self-describing JSON file. CSV broke down once windows carried
/// arrays (envelope, filtered envelope, 16 Mel bands) — a flat grid can't nest those, which is why
/// the CSV path needed 2-3 files. JSON nests scalars + arrays naturally and embeds the config, so a
/// file stays interpretable even after capture settings change. pandas reads it via json_normalize.
enum SessionJSON {

    /// Build the JSON data for a session.
    static func make(from session: SleepSession) throws -> Data {
        let iso = ISO8601DateFormatter()
        let windows = session.windows.sorted { $0.startTime < $1.startTime }

        let payload: [String: Any] = [
            "schema_version": 1,
            "session": [
                "start": iso.string(from: session.startTime),
                "end": session.endTime.map { iso.string(from: $0) } as Any,
                "duration_s": session.duration,
                "detection": session.detectionMethodRaw,
                "window_count": windows.count,
                // UTC offset (seconds) at capture, so timestamps can render in the local clock the
                // night was recorded in. nil on pre-feature sessions.
                "utc_offset_seconds": session.utcOffsetSeconds as Any,
            ],
            // Embed the capture config so the file is self-interpreting later.
            "config": [
                "window_seconds": SomnyaConfig.windowSeconds,
                "audio_envelope_hz": SomnyaConfig.audioEnvelopeHz,
                "breathing_min_bpm": SomnyaConfig.breathingMinBPM,
                "breathing_max_bpm": SomnyaConfig.breathingMaxBPM,
                "breathing_min_confidence": SomnyaConfig.breathingMinConfidence,
                "band_pass_low_hz": SomnyaConfig.breathingBandLowHz,
                "band_pass_high_hz": SomnyaConfig.breathingBandHighHz,
                "accel_envelope_hz": SomnyaConfig.accelEnvelopeHz,
            ],
            "windows": windows.map { windowDict($0, iso: iso) },
        ]

        return try JSONSerialization.data(withJSONObject: payload,
                                          options: [.prettyPrinted, .sortedKeys])
    }

    private static func windowDict(_ w: SensorWindow, iso: ISO8601DateFormatter) -> [String: Any] {
        var dict: [String: Any] = [
            "start": iso.string(from: w.startTime),
            "window_seconds": w.windowSeconds,
            // Accelerometer (always present).
            "accel_rms": w.accelRMS,
            "accel_jerk_rms": w.accelJerkRMS,
            "accel_activity_count": w.accelActivityCount,
            "accel_enmo_mean": w.accelENMOMean,
            "immobility_run_length": w.immobilityRunLength,
            "tilt_angle": w.tiltAngle,
            "posture_change_count": w.postureChangeCount,
            "assigned_stage": w.assignedStageRaw,
            "assigned_confidence": w.assignedConfidence,
        ]
        // Dense accel envelope (bed-motion breathing) — omit when absent (e.g. empty window).
        if let v = w.accelEnvelope { dict["accel_envelope"] = v }
        if let v = w.gyroEnvelope { dict["gyro_envelope"] = v }
        // Posture (mean gravity vector) + ambient pressure.
        if let v = w.gravityX { dict["gravity_x"] = v }
        if let v = w.gravityY { dict["gravity_y"] = v }
        if let v = w.gravityZ { dict["gravity_z"] = v }
        if let v = w.pressureKPa { dict["pressure_kpa"] = v }
        if let v = w.relativeAltitudeM { dict["relative_altitude_m"] = v }
        // Audio fields are nil on pre-analyzer or mic-off windows — omit rather than write nulls.
        if let v = w.audioRMS { dict["audio_rms"] = v }
        if let v = w.audioFloor { dict["audio_floor"] = v }
        if let v = w.breathingRate { dict["breathing_rate_bpm"] = v }
        if let v = w.breathingRateVariability { dict["breathing_rate_variability"] = v }
        if let v = w.breathingConfidence { dict["breathing_confidence"] = v }
        if let v = w.audioEnvelope { dict["envelope"] = v }
        if let v = w.audioEnvelopeFiltered { dict["filtered_envelope"] = v }
        if let v = w.melBandEnergies { dict["mel_bands"] = v }
        return dict
    }

    /// Write to a timestamped temp file for the share sheet.
    static func writeTempFile(for session: SleepSession) throws -> URL {
        let data = try make(from: session)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("somnya-session-\(stamp(for: session)).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Filename-safe timestamp for a session (its start time), e.g. 2026-06-10T08-59-33.
    private static func stamp(for session: SleepSession) -> String {
        session.startTime.formatted(.iso8601
            .year().month().day().dateSeparator(.dash)
            .time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
    }

    // MARK: - Batch zip export
    //
    // Bundle many sessions into ONE zip. Loose multi-file AirDrop dumps every file into Downloads to be
    // hunted down; a single dated zip is one accept and one tidy folder to unzip. Each night becomes
    // `somnya-session-<stamp>.json` inside the archive.
    //
    // Split into two phases so the slow part can run off the main thread WITHOUT a data race:
    //   • `serialize(_:)` reads the SwiftData managed objects (must be on the main actor) into plain
    //     Sendable Data blobs, collecting per-night failures rather than sinking the batch.
    //   • `zip(blobs:)` takes only Sendable values, so it's safe to run on a background task — this is
    //     the heavy file-write + compress that was freezing the UI.

    /// One night flattened to a Sendable blob: its session, its in-archive filename, and the JSON bytes.
    struct Blob { let session: SleepSession; let name: String; let data: Data }

    struct SerializeResult {
        let blobs: [Blob]
        let failed: [(session: SleepSession, error: Error)]
    }

    /// Main-actor: turn sessions into JSON blobs. Reads managed objects, so keep it on the main actor.
    @MainActor
    static func serialize(_ sessions: [SleepSession]) -> SerializeResult {
        var blobs: [Blob] = []
        var failed: [(SleepSession, Error)] = []
        for s in sessions {
            do { blobs.append(Blob(session: s, name: "somnya-session-\(stamp(for: s)).json", data: try make(from: s))) }
            catch { failed.append((s, error)) }
        }
        return SerializeResult(blobs: blobs, failed: failed)
    }

    /// Background-safe: write the blobs into a dated folder and zip it. Inputs are all Sendable (name +
    /// Data), so no managed objects cross the thread boundary. Returns the finished zip's URL.
    static func zip(blobs: [(name: String, data: Data)]) throws -> URL {
        guard !blobs.isEmpty else { throw ExportError.nothingToExport }
        let fm = FileManager.default
        // Name the folder by date so it lands as a clean `somnya-export-2026-06-14/` on the Mac (not a
        // raw epoch). Remove any stale same-day staging/zip first so a re-export doesn't clobber.
        let dateStamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let folderName = "somnya-export-\(dateStamp)"
        let stageDir = fm.temporaryDirectory.appendingPathComponent(folderName, isDirectory: true)
        try? fm.removeItem(at: stageDir)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        for b in blobs {
            try b.data.write(to: stageDir.appendingPathComponent(b.name), options: .atomic)
        }

        // Zip via NSFileCoordinator(.forUploading): reads a folder and hands back a temp zip of it.
        // Copy that out to a stable URL (the coordinator's temp is reclaimed when the block exits).
        let zipURL = fm.temporaryDirectory.appendingPathComponent("\(folderName).zip")
        try? fm.removeItem(at: zipURL)
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: stageDir, options: [.forUploading],
                                       error: &coordError) { tmpZip in
            do { try fm.copyItem(at: tmpZip, to: zipURL) }
            catch { copyError = error }
        }
        if let coordError { throw coordError }
        if let copyError { throw copyError }
        try? fm.removeItem(at: stageDir)  // staging no longer needed once zipped
        return zipURL
    }

    enum ExportError: LocalizedError {
        case nothingToExport
        var errorDescription: String? {
            switch self {
            case .nothingToExport:
                return "No sessions could be exported. They may have no recorded windows, or storage is full — free up space and try again."
            }
        }
    }
}
