import Foundation
import AVFoundation

/// Emits a CLEAN, phone-generated sine tone at a chosen frequency, so the near-ultrasound sonar
/// band (18-22 kHz) can be comfort-tested honestly — unlike a re-encoded YouTube clip, whose
/// artifacts produce audible lower-frequency garbage that can cause a headache even when the
/// nominal tone is inaudible. Generated mathematically here = no encoding artifacts.
///
/// This is a DIAGNOSTIC, not the sonar pipeline: just "play this exact frequency and see if it
/// bothers you (or anything around you)." Volume is deliberately controllable and starts modest.
@MainActor
final class ToneTester: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published var frequency: Double = 19000   // mid sonar band
    @Published var amplitude: Double = 0.15     // conservative; this is unamplified by AGC

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var phase: Double = 0
    private var sampleRate: Double = 48000

    /// Frequencies worth testing: just below the band, the academic sonar band, and the ceiling.
    static let testFrequencies: [Double] = [15000, 17000, 18000, 19000, 20000, 22000]

    func start() {
        guard !isPlaying else { return }

        let output = engine.outputNode
        sampleRate = output.outputFormat(forBus: 0).sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        let freq = frequency
        let amp = amplitude
        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let inc = 2.0 * Double.pi * freq / self.sampleRate
            // Read phase locally to avoid touching @MainActor state from the render thread.
            var localPhase = self.phase
            for frame in 0..<Int(frameCount) {
                let value = Float(sin(localPhase) * amp)
                localPhase += inc
                if localPhase > 2 * Double.pi { localPhase -= 2 * Double.pi }
                for buffer in abl {
                    let buf = UnsafeMutableBufferPointer<Float>(buffer)
                    buf[frame] = value
                }
            }
            self.phase = localPhase
            return noErr
        }
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: output, format: format)

        do {
            // Playback only — this is a comfort test, not capture. Mix so it doesn't seize audio.
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            isPlaying = true
            SomnyaLog.capture("Tone test STARTED freq=\(Int(freq))Hz amp=\(amp)")
        } catch {
            SomnyaLog.capture("Tone test FAILED to start: \(error.localizedDescription). Check the device isn't on silent and volume is up.")
            cleanup()
        }
    }

    func stop() {
        guard isPlaying else { return }
        engine.stop()
        cleanup()
        SomnyaLog.capture("Tone test STOPPED")
    }

    private func cleanup() {
        if let node = sourceNode {
            engine.detach(node)
            sourceNode = nil
        }
        isPlaying = false
    }
}
