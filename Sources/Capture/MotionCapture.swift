import Foundation
import CoreMotion

/// One decimated motion sample fed to the window aggregator.
struct MotionSample {
    let timestamp: Date
    /// userAcceleration (gravity removed) in g, per axis.
    let ax: Double
    let ay: Double
    let az: Double
    /// Device attitude — pitch/roll used for tilt/orientation features.
    let pitch: Double
    let roll: Double
}

/// CMMotionManager wrapper: captures device motion at 50 Hz and decimates to 10 Hz for
/// analysis (every 5th sample). Needs NO permission dialog — CMMotionManager device-motion
/// is freely available. Logs each delivered sample's arrival to the `capture` category so
/// "the sensor is actually delivering data" is provable on-device.
final class MotionCapture {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()

    private let captureHz: Double = 50
    private let decimationFactor = 5   // 50 Hz → 10 Hz
    private var rawCount = 0

    /// Called with each decimated (10 Hz) sample. Set by the aggregator.
    var onSample: ((MotionSample) -> Void)?

    /// True once we've asked CoreMotion to start AND it's available. This is the honest
    /// "is it running" signal — `isDeviceMotionActive` reads false in the instant right after
    /// start(), so we don't rely on it for the guardrail.
    private(set) var isActive = false

    /// Set true the first time a real sample is delivered — proof of actual data flow.
    private(set) var hasDeliveredSample = false

    /// Called once when the first sample arrives, so callers can re-check guardrails.
    var onFirstSample: (() -> Void)?

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard manager.isDeviceMotionAvailable else {
            SomnyaLog.capture("Device motion NOT available (simulator or unsupported device). No motion will be recorded.")
            isActive = false
            return
        }
        guard !isActive else { return }

        manager.deviceMotionUpdateInterval = 1.0 / captureHz
        rawCount = 0
        queue.maxConcurrentOperationCount = 1

        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, error in
            guard let self else { return }
            if let error {
                SomnyaLog.capture("Motion update error: \(error.localizedDescription)")
                return
            }
            guard let motion else { return }

            // First real sample → flip the proof flag and notify (for guardrail re-check).
            if !self.hasDeliveredSample {
                self.hasDeliveredSample = true
                let cb = self.onFirstSample
                if let cb { OperationQueue.main.addOperation(cb) }
            }

            self.rawCount += 1
            // Decimate: keep every 5th sample (50 Hz → 10 Hz).
            guard self.rawCount % self.decimationFactor == 0 else { return }

            let sample = MotionSample(
                timestamp: Date(),
                ax: motion.userAcceleration.x,
                ay: motion.userAcceleration.y,
                az: motion.userAcceleration.z,
                pitch: motion.attitude.pitch,
                roll: motion.attitude.roll
            )

            // Heartbeat log ~ once/sec (every 10th decimated sample) so the log proves
            // delivery without flooding.
            if self.rawCount % (self.decimationFactor * 10) == 0 {
                SomnyaLog.capture(String(format: "motion alive — ax=%.3f ay=%.3f az=%.3f", sample.ax, sample.ay, sample.az))
            }

            self.onSample?(sample)
        }

        // Available + started = active (don't trust isDeviceMotionActive synchronously).
        isActive = true
        hasDeliveredSample = false
        SomnyaLog.capture("Device motion STARTED at \(captureHz)Hz → \(captureHz / Double(decimationFactor))Hz analysis.")
    }

    func stop() {
        guard isActive else { return }
        manager.stopDeviceMotionUpdates()
        isActive = false
        hasDeliveredSample = false
        onFirstSample = nil
        SomnyaLog.capture("Device motion STOPPED")
    }
}
