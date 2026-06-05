import Foundation
import AVFoundation

/// Holds an audio session so the app keeps running when the phone locks. This is the only
/// way iOS lets a sensor app persist with the screen off — the accelerometer rides along on
/// the process this keeps alive. Records at a low sample rate (2 kHz target, per spec) since
/// breathing rate comes from the slow envelope, not the audio spectrum.
///
/// It installs a tap that does two jobs: (1) keepalive — holding the audio session open keeps
/// the app (and the accelerometer) running with the screen locked; (2) feeding each buffer to
/// the AudioAnalyzer, which extracts breathing features without retaining the raw waveform.
final class AudioKeepalive {
    private let engine = AVAudioEngine()
    private var installed = false

    /// The analyzer that turns mic buffers into breathing features. Owned here so the tap can
    /// feed it; SessionManager reads window snapshots from it at each 30s flush.
    let analyzer = AudioAnalyzer()

    /// Target analysis sample rate. The hardware mic runs at its native rate; we note the
    /// target and (later) downsample in the analyzer.
    let targetSampleRate: Double = 2000

    private(set) var isActive = false

    /// Heartbeat: number of audio buffers seen, so we can prove flow without flooding logs.
    private var bufferCount = 0

    /// Start the audio session + engine. Returns false if it couldn't start (e.g. permission
    /// denied or activation failed) so the caller can reflect that honestly in guardrails.
    @discardableResult
    func start() -> Bool {
        guard !isActive else { return true }

        let session = AVAudioSession.sharedInstance()
        do {
            // .playAndRecord (NOT .record): .record seizes the audio route and silences other
            // apps — so falling asleep to music/podcast/white-noise would stop the moment a
            // session starts. .playAndRecord + .mixWithOthers lets capture coexist with playback.
            // Mode .default (NOT .measurement): .measurement disables the system's input gain for
            // calibrated capture, which buries faint breathing in the noise floor; .default keeps
            // gain/AGC on so quiet breathing can rise above the floor at nightstand distance.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            SomnyaLog.capture("Audio session activation FAILED: \(error.localizedDescription). Tracking may stop when the screen locks. Check microphone permission in Settings → Somnya.")
            isActive = false
            return false
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        bufferCount = 0

        analyzer.reset()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.analyzer.process(buffer)
            self.bufferCount += 1
            // ~once/sec-ish heartbeat depending on buffer size, throttled. Includes the live
            // loudness so the Debug log shows the mic is hearing something, not just alive.
            if self.bufferCount % 50 == 0 {
                SomnyaLog.capture(String(format: "audio alive — buffers=%d hwRate=%dHz rms=%.4f floor=%.4f",
                                         self.bufferCount, Int(format.sampleRate),
                                         self.analyzer.lastRMS, self.analyzer.noiseFloor))
            }
        }
        installed = true

        do {
            engine.prepare()
            try engine.start()
        } catch {
            SomnyaLog.capture("Audio engine start FAILED: \(error.localizedDescription).")
            input.removeTap(onBus: 0)
            installed = false
            isActive = false
            return false
        }

        isActive = true
        SomnyaLog.capture("Audio keepalive STARTED (hwRate=\(Int(format.sampleRate))Hz, target=\(Int(targetSampleRate))Hz). App will stay alive with screen locked.")
        return true
    }

    func stop() {
        guard isActive else { return }
        if installed {
            engine.inputNode.removeTap(onBus: 0)
            installed = false
        }
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        isActive = false
        SomnyaLog.capture("Audio keepalive STOPPED")
    }
}
