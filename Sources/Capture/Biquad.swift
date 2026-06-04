import Foundation

/// A pair of cascaded biquad filters forming a band-pass: a high-pass to kill DC/rumble below the
/// breathing band, then a low-pass to kill high-frequency noise (birds, hiss, speech sibilance).
/// Breathing airflow sound lives roughly 50–1000 Hz; isolating that band BEFORE building the
/// loudness envelope is what actually rejects noise — unlike gain, which scales noise too.
///
/// Direct-form-I biquad. Coefficients per the Audio EQ Cookbook (RBJ). Stateful: feed samples in
/// order; call reset() between sessions. Pure Swift, unit-testable without audio hardware.
struct BandPassFilter {
    private var highPass: Biquad
    private var lowPass: Biquad

    init(sampleRate: Double,
         lowCutoffHz: Double = SomnyaConfig.breathingBandLowHz,
         highCutoffHz: Double = SomnyaConfig.breathingBandHighHz,
         q: Double = 0.707) {
        // High-pass at the low edge (remove everything below the band), low-pass at the high edge.
        highPass = Biquad.highPass(sampleRate: sampleRate, cutoff: lowCutoffHz, q: q)
        lowPass = Biquad.lowPass(sampleRate: sampleRate, cutoff: highCutoffHz, q: q)
    }

    /// Filter one sample through both stages.
    mutating func process(_ x: Double) -> Double {
        lowPass.process(highPass.process(x))
    }

    mutating func reset() {
        highPass.reset()
        lowPass.reset()
    }
}

/// Single direct-form-I biquad section.
struct Biquad {
    // Normalized coefficients (a0 divided out).
    private let b0, b1, b2, a1, a2: Double
    // State.
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    private init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }

    mutating func reset() { x1 = 0; x2 = 0; y1 = 0; y2 = 0 }

    // MARK: - RBJ cookbook designs

    static func lowPass(sampleRate: Double, cutoff: Double, q: Double) -> Biquad {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * q)
        let a0 = 1 + alpha
        return Biquad(
            b0: ((1 - cw) / 2) / a0,
            b1: (1 - cw) / a0,
            b2: ((1 - cw) / 2) / a0,
            a1: (-2 * cw) / a0,
            a2: (1 - alpha) / a0
        )
    }

    static func highPass(sampleRate: Double, cutoff: Double, q: Double) -> Biquad {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * q)
        let a0 = 1 + alpha
        return Biquad(
            b0: ((1 + cw) / 2) / a0,
            b1: (-(1 + cw)) / a0,
            b2: ((1 + cw) / 2) / a0,
            a1: (-2 * cw) / a0,
            a2: (1 - alpha) / a0
        )
    }
}
