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

    /// Bundle many sessions into ONE zip for export. Loose multi-file AirDrop dumps every file into
    /// Downloads to be hunted down; a single `somnya-export.zip` is one accept and one tidy file to
    /// unzip wherever you like. Each night becomes `somnya-session-<stamp>.json` inside the archive.
    /// Returns the zip plus the sessions that made it in (so the caller can stamp `exportedAt`) and any
    /// that failed to serialize (surfaced, not fatal — one bad night doesn't sink the batch).
    struct ZipResult {
        let url: URL
        let included: [SleepSession]
        let failed: [(session: SleepSession, error: Error)]
    }

    static func writeZip(for sessions: [SleepSession]) throws -> ZipResult {
        let fm = FileManager.default
        // Stage the JSONs in a folder; zipping the folder yields one archive that unzips to that folder.
        // Name it by date so it lands as a clean `somnya-export-2026-06-14/` on the Mac (not a raw
        // epoch). Remove any stale same-day staging/zip first so a re-export doesn't append/clobber.
        let dateStamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let folderName = "somnya-export-\(dateStamp)"
        let stageDir = fm.temporaryDirectory.appendingPathComponent(folderName, isDirectory: true)
        try? fm.removeItem(at: stageDir)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)

        var included: [SleepSession] = []
        var failed: [(SleepSession, Error)] = []
        for s in sessions {
            do {
                let data = try make(from: s)
                try data.write(to: stageDir.appendingPathComponent("somnya-session-\(stamp(for: s)).json"),
                               options: .atomic)
                included.append(s)
            } catch {
                failed.append((s, error))
            }
        }
        guard !included.isEmpty else {
            throw ExportError.nothingToExport
        }

        // Zip via NSFileCoordinator(.forUploading): reads a folder and hands back a temp zip of it.
        // We copy that out to a stable URL (the coordinator's temp is reclaimed when the block exits).
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

        return ZipResult(url: zipURL, included: included, failed: failed)
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
