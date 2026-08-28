import Foundation
import AVFoundation

/// Live sound-level meter for one-time dB-SPL calibration. Plays nothing; it only LISTENS, computing
/// the exact same raw RMS the real capture pipeline persists as `audio_rms` (so the offset it derives
/// is valid for recorded nights), and exposes it as a running dBFS reading plus a stable average.
///
/// Why this exists: `audio_rms` is uncalibrated electrical amplitude — proportional to loudness but
/// with no real-world anchor, because every phone's mic sensitivity differs. To show real decibels
/// (the "30=whisper, 60=conversation, 85=traffic" scale people understand), we need ONE per-device
/// offset: play a steady sound, read our dBFS and a reference SPL meter at the same moment, and the
/// difference is the offset. This screen measures our side; the user supplies the reference reading.
///
/// IMPORTANT — it mirrors `AudioKeepalive`'s session config (.playAndRecord, mode .default, AGC ON).
/// The real recordings run with AGC on (so quiet breathing rises above the floor), so we MUST
/// calibrate through that same path or the offset wouldn't apply to recorded data. AGC means the gain
/// drifts a little, so the offset is necessarily APPROXIMATE (±a few dB) — which is exactly why the
/// resulting dB-SPL is presented as ESTIMATED, never as a precision instrument.
@MainActor
final class CalibrationTester: ObservableObject {
    /// Live (most-recent-buffer) level in dBFS — moves in real time as the room changes.
    @Published private(set) var liveDBFS: Double = -120
    /// Rolling average of dBFS over the active measurement — the stable number to compare to the meter.
    @Published private(set) var averageDBFS: Double = -120
    /// How many buffers have folded into the current average (a confidence/duration cue for the user).
    @Published private(set) var sampleCount: Int = 0
    @Published private(set) var isMeasuring = false
    /// Set if the mic couldn't start — surfaced to the user with a fix, never a silent failure.
    @Published private(set) var errorMessage: String?

    private let engine = AVAudioEngine()
    private var installed = false

    // Running mean of buffer RMS (linear, NOT of dB — averaging in the linear domain is the
    // physically correct way to pool power before converting once to dB at the end).
    private var rmsSum: Double = 0
    private var rmsCount: Int = 0

    func start() {
        guard !isMeasuring else { return }
        errorMessage = nil
        rmsSum = 0; rmsCount = 0; sampleCount = 0

        let session = AVAudioSession.sharedInstance()
        do {
            // Mirror AudioKeepalive EXACTLY so the level we measure matches recorded nights.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: AudioSessionConfig.captureOptions)
            try session.setActive(true)
        } catch {
            errorMessage = "Couldn't start the microphone. Make sure mic permission is granted (Settings → Somnya → Microphone) and the phone isn't in a call, then try again."
            return
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            // EXACT same RMS as AudioAnalyzer.process: sqrt(mean(sample^2)) on raw float samples.
            var sumSq: Double = 0
            for i in 0..<n {
                let v = Double(channel[i])
                sumSq += v * v
            }
            let rms = (sumSq / Double(n)).squareRoot()
            Task { @MainActor in self.ingest(rms: rms) }
        }
        installed = true

        do {
            engine.prepare()
            try engine.start()
            isMeasuring = true
            SomnyaLog.capture("Calibration meter STARTED (hwRate=\(Int(format.sampleRate))Hz)")
        } catch {
            input.removeTap(onBus: 0)
            installed = false
            errorMessage = "The audio engine failed to start (\(error.localizedDescription)). Close other audio apps and try again."
        }
    }

    /// Reset the rolling average without stopping the meter — for re-measuring at a new level.
    func resetAverage() {
        rmsSum = 0; rmsCount = 0; sampleCount = 0
        averageDBFS = -120
    }

    func stop() {
        guard isMeasuring else { return }
        if installed {
            engine.inputNode.removeTap(onBus: 0)
            installed = false
        }
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        isMeasuring = false
        SomnyaLog.capture("Calibration meter STOPPED")
    }

    private func ingest(rms: Double) {
        liveDBFS = SomnyaConfig.dbFS(fromRMS: rms)
        rmsSum += rms
        rmsCount += 1
        sampleCount = rmsCount
        averageDBFS = SomnyaConfig.dbFS(fromRMS: rmsSum / Double(rmsCount))
    }

    /// Given the reference SPL meter's reading for the same steady sound, compute and PERSIST the
    /// per-device offset: offset = referenceDB − ourAverageDBFS. After this, dB-SPL is available
    /// app-wide via SomnyaConfig.dbSPL(fromRMS:). Returns the offset for display.
    @discardableResult
    func calibrate(referenceDB: Double) -> Double {
        let offset = referenceDB - averageDBFS
        SomnyaConfig.userSPLOffsetDB = offset
        SomnyaLog.capture(String(format: "SPL calibrated: ref=%.1f dB, ourAvg=%.1f dBFS → offset=%.1f dB",
                                 referenceDB, averageDBFS, offset))
        return offset
    }
}
