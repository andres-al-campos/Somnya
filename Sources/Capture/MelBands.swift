import Foundation
import Accelerate

/// Computes Mel-band energies from audio buffers. Per the accuracy research, ~10-20 Mel bands
/// over the low spectrum are what a future LEARNED breathing/staging model needs — and they
/// CANNOT be recomputed later without the raw waveform, so we capture them now even though no
/// model consumes them yet. We accumulate band energy across a window and emit the per-window
/// average, so storage stays tiny (one short vector per 30s window).
///
/// This is intentionally simple (a power-spectrum binned onto a Mel-spaced filterbank), not a full
/// MFCC — we want the raw band energies, not cepstral coefficients, for an unknown future model.
final class MelBandExtractor {
    let bandCount: Int
    private let fftSize: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let sampleRate: Double

    /// Mel filterbank: for each band, the [startBin, endBin) range over the FFT magnitude bins.
    private let bandRanges: [(Int, Int)]

    /// Running accumulation across a window.
    private var accum: [Double]
    private var frameCount = 0

    /// Scratch buffers reused per frame (avoid per-call allocation on the audio thread).
    private var windowFunc: [Float]
    private var realp: [Float]
    private var imagp: [Float]

    init?(sampleRate: Double, fftSize: Int = 1024, bandCount: Int = 16,
          minHz: Double = SomnyaConfig.breathingBandLowHz,
          maxHz: Double = SomnyaConfig.breathingBandHighHz) {
        guard fftSize > 0, (fftSize & (fftSize - 1)) == 0 else { return nil }  // power of two
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.bandCount = bandCount
        self.log2n = vDSP_Length(log2(Double(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.fftSetup = setup

        self.accum = [Double](repeating: 0, count: bandCount)
        self.windowFunc = [Float](repeating: 0, count: fftSize)
        self.realp = [Float](repeating: 0, count: fftSize / 2)
        self.imagp = [Float](repeating: 0, count: fftSize / 2)
        vDSP_hann_window(&windowFunc, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        // Mel-spaced band edges mapped to FFT bins, clamped to the [minHz, maxHz] band of interest.
        let mel = { (f: Double) in 2595.0 * log10(1 + f / 700.0) }
        let invMel = { (m: Double) in 700.0 * (pow(10, m / 2595.0) - 1) }
        let mMin = mel(minHz), mMax = mel(maxHz)
        let binHz = sampleRate / Double(fftSize)
        var ranges: [(Int, Int)] = []
        for b in 0..<bandCount {
            let lo = invMel(mMin + (mMax - mMin) * Double(b) / Double(bandCount))
            let hi = invMel(mMin + (mMax - mMin) * Double(b + 1) / Double(bandCount))
            let loBin = max(0, Int(lo / binHz))
            let hiBin = min(fftSize / 2, max(loBin + 1, Int(hi / binHz)))
            ranges.append((loBin, hiBin))
        }
        self.bandRanges = ranges
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Feed one frame (fftSize samples). Shorter inputs are zero-padded; longer are truncated.
    /// Accumulates this frame's per-band power into the window total.
    func ingestFrame(_ samples: [Float]) {
        var frame = samples
        if frame.count < fftSize {
            frame.append(contentsOf: [Float](repeating: 0, count: fftSize - frame.count))
        } else if frame.count > fftSize {
            frame = Array(frame.prefix(fftSize))
        }

        // Window the frame.
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(frame, 1, windowFunc, 1, &windowed, 1, vDSP_Length(fftSize))

        // Pack real input into split-complex and run the forward FFT.
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    let cplx = raw.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(cplx.baseAddress!, 2, &split, 1, vDSP_Length(fftSize / 2))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // Power spectrum = real^2 + imag^2.
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        // Sum power into each Mel band.
        for (i, (lo, hi)) in bandRanges.enumerated() where hi > lo {
            var sum: Float = 0
            magnitudes.withUnsafeBufferPointer { mp in
                vDSP_sve(mp.baseAddress! + lo, 1, &sum, vDSP_Length(hi - lo))
            }
            accum[i] += Double(sum)
        }
        frameCount += 1
    }

    /// Per-window average band energies, then reset for the next window. nil if no frames seen.
    func snapshot() -> [Double]? {
        guard frameCount > 0 else { return nil }
        let out = accum.map { $0 / Double(frameCount) }
        accum = [Double](repeating: 0, count: bandCount)
        frameCount = 0
        return out
    }

    func reset() {
        accum = [Double](repeating: 0, count: bandCount)
        frameCount = 0
    }
}
