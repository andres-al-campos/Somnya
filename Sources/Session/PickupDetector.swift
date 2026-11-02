import Foundation

/// Ends the night when the phone is picked up after sleep and doesn't come back to rest with
/// someone beside it. A port of `auto_stop` in `analysis/somnya_analyze/autostop.py`; change the two
/// together.
///
/// A pickup only marks a possible end, since turning off the alarm and going back to sleep is a
/// normal morning. Recording carries on, and the pickup stands if the phone never settles again, or
/// settles and then feels no movement for as long as it would on a table. On 142 nights (Jun-Nov
/// 2026) a phone set back down on the bed nearly always settled within minutes.
struct PickupDetector {
    struct Reading {
        let start: Date
        let seconds: Double
        let gravity: (x: Double, y: Double, z: Double)?
        let gyro: Double
        let activity: Double
    }

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
    /// Still for this long after a pickup means it's back at rest and the night may go on.
    static let settleSeconds: Double = 5 * 60
    /// In hand or on the move this long after a pickup: the night is over.
    static let settleWaitSeconds: Double = 15 * 60
    /// No movement for this long after settling means nobody's there. Back-to-sleep mornings went up
    /// to 62 min between movements. Too long only records a little extra, which is then trimmed.
    static let restSeconds: Double = 120 * 60

    private var lastGravity: (Double, Double, Double)?
    private var onBedSeconds: Double = 0
    private var stillSeconds: Double = 0
    private var offRun: [Date] = []
    private var pickup: Date?
    private var settled: Date?
    private var lastMovementEnd: Date?

    /// Where the night should end if it's stopped now, when that's earlier than now: the pickup, if
    /// nothing has moved since.
    var restingEnd: Date? { lastMovementEnd == nil ? pickup : nil }

    /// Feed each saved window in order. Returns when the night ended, once that's decided, or nil.
    mutating func observe(_ r: Reading) -> Date? {
        guard let g = r.gravity else { return nil }
        var dGravity = 0.0
        if let (px, py, pz) = lastGravity {
            dGravity = sqrt((g.x - px) * (g.x - px) + (g.y - py) * (g.y - py) + (g.z - pz) * (g.z - pz))
        }
        lastGravity = (g.x, g.y, g.z)
        let off = !(dGravity < Self.gravityBar && r.gyro < Self.gyroBar)

        if off {
            offRun.append(r.start)
            stillSeconds = 0
        } else {
            onBedSeconds += r.seconds
            stillSeconds += r.seconds
            offRun.removeAll()
        }
        guard onBedSeconds >= Self.armedSeconds else { return nil }

        // A pickup, or another one after settling.
        if offRun.count >= Self.offWindows, pickup == nil || settled != nil {
            pickup = offRun.first
            settled = nil
            lastMovementEnd = nil
        }
        guard let pickup else { return nil }

        guard let settledAt = settled else {
            if stillSeconds >= Self.settleSeconds {
                settled = r.start
            } else if r.start.timeIntervalSince(pickup) >= Self.settleWaitSeconds {
                return pickup
            }
            return nil
        }
        if !off, r.activity >= SomnyaConfig.movementThreshold {
            lastMovementEnd = r.start.addingTimeInterval(r.seconds)
        }
        if r.start.timeIntervalSince(lastMovementEnd ?? settledAt) >= Self.restSeconds {
            return lastMovementEnd ?? pickup
        }
        return nil
    }
}
