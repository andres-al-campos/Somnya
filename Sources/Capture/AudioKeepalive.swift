import Foundation
import AVFoundation
import UIKit

/// The capture session's category options, in one place because
/// CalibrationTester must mirror them exactly — a measured level only matches
/// recorded nights if the route is configured identically.
///
/// `.allowBluetooth` was renamed `.allowBluetoothHFP` in iOS 26. The old name
/// still works but warns, and the new one doesn't exist below 26, so the
/// deployment target (iOS 17) rules out a plain rename.
enum AudioSessionConfig {
    /// `AVAudioSessionCategoryOptionAllowBluetooth`, spelled by raw value.
    ///
    /// Referring to `.allowBluetooth` by name warns: iOS 26 renamed it to
    /// `.allowBluetoothHFP` and back-dated the deprecation to iOS 8.0, so even
    /// a correctly `#available`-guarded use trips it. The value is fixed ABI —
    /// `= 0x4` in AVAudioSessionTypes.h — since it crosses into C.
    private static let allowBluetoothLegacy = AVAudioSession.CategoryOptions(rawValue: 0x4)

    static var captureOptions: AVAudioSession.CategoryOptions {
        if #available(iOS 26.0, *) {
            return [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP]
        } else {
            return [.mixWithOthers, .defaultToSpeaker, allowBluetoothLegacy]
        }
    }
}

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

    private var observers: [NSObjectProtocol] = []
    private var retryTimer: Timer?
    private var retryTask = UIBackgroundTaskIdentifier.invalid

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
                                    options: AudioSessionConfig.captureOptions)
            try session.setActive(true)
        } catch {
            SomnyaLog.capture("Audio session activation FAILED: \(error.localizedDescription). Tracking may stop when the screen locks. Check microphone permission in Settings → Somnya.")
            isActive = false
            return false
        }

        bufferCount = 0
        analyzer.reset()
        guard startEngine() else {
            isActive = false
            return false
        }

        isActive = true
        observeInterruptions()
        SomnyaLog.capture("Audio keepalive STARTED (hwRate=\(Int(engine.inputNode.outputFormat(forBus: 0).sampleRate))Hz, target=\(Int(targetSampleRate))Hz). App will stay alive with screen locked.")
        return true
    }

    private func startEngine() -> Bool {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
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
            return false
        }
        return true
    }

    // MARK: - Interruptions

    /// An alarm or call stops the engine, and with nothing recording iOS suspends the app about half
    /// a minute later. Nights ended that way at the alarm, 7:35 again and again, until this restarted
    /// it. iOS doesn't promise an "ended" notice to a background app, so it keeps trying as well,
    /// for as long as a background task holds the app awake.
    private func observeInterruptions() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
                guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
                SomnyaLog.capture("Audio interrupted, type \(raw) (1 began, 0 ended)")
                if AVAudioSession.InterruptionType(rawValue: raw) == .began {
                    self.keepTryingToRestart()
                } else {
                    self.restart()
                }
            },
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                SomnyaLog.capture("Audio route changed; restarting the engine")
                self?.keepTryingToRestart()
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
                SomnyaLog.capture("Media services reset; restarting the engine")
                self?.keepTryingToRestart()
            },
        ]
    }

    private func keepTryingToRestart() {
        guard isActive, retryTimer == nil else { return }
        retryTask = UIApplication.shared.beginBackgroundTask { [weak self] in self?.stopTrying() }
        if restart() { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.restart() }
    }

    @discardableResult
    private func restart() -> Bool {
        guard isActive else { return false }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            return false
        }
        if !engine.isRunning {
            if installed {
                engine.inputNode.removeTap(onBus: 0)
                installed = false
            }
            guard startEngine() else { return false }
        }
        SomnyaLog.capture("Audio keepalive restarted")
        stopTrying()
        return true
    }

    private func stopTrying() {
        retryTimer?.invalidate()
        retryTimer = nil
        if retryTask != .invalid {
            UIApplication.shared.endBackgroundTask(retryTask)
            retryTask = .invalid
        }
    }

    func stop() {
        guard isActive else { return }
        stopTrying()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
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
