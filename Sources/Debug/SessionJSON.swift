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
        let stamp = session.startTime.formatted(.iso8601
            .year().month().day().dateSeparator(.dash)
            .time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("somnya-session-\(stamp).json")
        try data.write(to: url, options: .atomic)
        return url
    }
}
