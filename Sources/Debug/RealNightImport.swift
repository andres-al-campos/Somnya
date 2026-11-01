import Foundation
import SwiftData

#if targetEnvironment(simulator)

/// Loads real exported nights into the simulator, so the Night screen can be looked at with the
/// owner's own data and a "usual" built from real neighbours. Drop uncompressed exports into the
/// app container's Documents/import folder (`xcrun simctl get_app_container booted <bundle id> data`)
/// and launch: each file becomes a session, then is deleted.
///
/// Audio envelopes, gyro and mel bands are skipped: nothing on the Night screen reads them, and
/// they are most of a file's size. The accelerometer envelope comes along for heart rate.
enum RealNightImport {
    static let tag = "imported"

    static func run(into context: ModelContext) -> Int {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return 0 }
        let folder = docs.appendingPathComponent("import")
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var imported = 0
        for url in files where url.pathExtension == "json" {
            if let session = load(url) {
                context.insert(session)
                try? context.save()
                imported += 1
            }
            try? fm.removeItem(at: url)
        }
        return imported
    }

    private static func load(_ url: URL) -> SleepSession? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = root["session"] as? [String: Any],
              let rows = root["windows"] as? [[String: Any]] else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ v: Any?) -> Date? {
            guard let s = v as? String else { return nil }
            return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        guard let start = date(meta["start"]) else { return nil }

        let session = SleepSession(startTime: start, detectionMethod: .gesture)
        session.endTime = date(meta["end"])
        session.utcOffsetSeconds = meta["utc_offset_seconds"] as? Int
        session.tags = [tag]
        for r in rows {
            guard let t = date(r["start"]) else { continue }
            let w = SensorWindow(
                startTime: t,
                windowSeconds: r["window_seconds"] as? Double ?? SomnyaConfig.windowSeconds,
                accelRMS: r["accel_rms"] as? Double ?? 0,
                accelJerkRMS: r["accel_jerk_rms"] as? Double ?? 0,
                accelActivityCount: r["accel_activity_count"] as? Double ?? 0,
                accelENMOMean: r["accel_enmo_mean"] as? Double ?? 0,
                immobilityRunLength: r["immobility_run_length"] as? Int ?? 0,
                tiltAngle: r["tilt_angle"] as? Double ?? 0,
                postureChangeCount: r["posture_change_count"] as? Int ?? 0,
                accelEnvelope: r["accel_envelope"] as? [Double],
                gravityX: r["gravity_x"] as? Double,
                gravityY: r["gravity_y"] as? Double,
                gravityZ: r["gravity_z"] as? Double,
                audioRMS: r["audio_rms"] as? Double,
                audioFloor: r["audio_floor"] as? Double,
                breathingRate: r["breathing_rate_bpm"] as? Double,
                breathingConfidence: r["breathing_confidence"] as? Double)
            session.windows.append(w)
        }
        return session
    }
}

#endif
