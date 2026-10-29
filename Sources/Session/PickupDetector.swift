import Foundation

/// Ends the night when the phone is picked up after sleep, usually to stop the alarm. A port of
/// `auto_stop` in `analysis/somnya_analyze/autostop.py`; change the two together.
///
/// It doesn't try to tell a morning pickup from one in the night: a pickup ends the night either
/// way. On 134 nights (Jun–Oct 2026) the chosen settings ended 100, and 8 of those more than 15
/// minutes before the estimated wake — which also counts nights of dozing off again after the
/// alarm, so the true mid-night share is lower.
struct PickupDetector {
    /// Gravity moved or the gyro was busy: the same bars as `classify_phone_state`.
    static let gravityBar = 0.015
    static let gyroBar = 0.015
    /// On-the-bed time before a pickup counts, so the minutes in hand before setting the phone
    /// down never end the night.
    static let armedSeconds: Double = 120 * 60
    /// Consecutive off-the-bed windows that make a pickup. One window can be a hard roll-over
    /// shifting the phone; two in a row (a minute) was the sweep's balance: one window ended
    /// 124 nights with 13 early, three ended 19.
    static let offWindows = 2

    private var lastGravity: (Double, Double, Double)?
    private var onBedSeconds: Double = 0
    private var offRun: [Date] = []

    /// Feed each saved window in order. Returns when the phone was picked up (the first window of
    /// the off-the-bed run) once that run is long enough, or nil.
    mutating func observe(_ w: SensorWindow) -> Date? {
        guard let gx = w.gravityX, let gy = w.gravityY, let gz = w.gravityZ else { return nil }
        var dGravity = 0.0
        if let (px, py, pz) = lastGravity {
            dGravity = sqrt((gx - px) * (gx - px) + (gy - py) * (gy - py) + (gz - pz) * (gz - pz))
        }
        lastGravity = (gx, gy, gz)
        let gyro = w.gyroEnvelope.flatMap { $0.isEmpty ? nil : $0.reduce(0, +) / Double($0.count) } ?? 0
        let off = !(dGravity < Self.gravityBar && gyro < Self.gyroBar)

        guard off else {
            onBedSeconds += w.windowSeconds
            offRun.removeAll()
            return nil
        }
        offRun.append(w.startTime)
        guard onBedSeconds >= Self.armedSeconds, offRun.count >= Self.offWindows else { return nil }
        return offRun.first
    }
}
