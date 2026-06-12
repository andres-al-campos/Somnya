import Foundation

/// Heart rate from the accelerometer envelope (ballistocardiography) — a faithful Swift port of the
/// Python two-pass tracker (analysis/somnya_analyze/stats.py `_heartbeat_series`), kept in sync so the
/// app's HR track agrees with the offline tooling.
///
/// The BCG signal is a sharp, harmonic-rich pulse ~25x weaker than breathing, so the autocorrelation
/// often has a peak at 2x the true rate that's TALLER than the fundamental — naively taking the tallest
/// peak flips between e.g. 51 and 95 bpm. Defenses, all ported verbatim:
///   1. A SHARP 4th-order Butterworth band-pass (40–120 bpm), zero-phase (filtfilt), to isolate the
///      heart band before autocorrelating — a gentle filter leaks the huge breathing wave in.
///   2. A global-median SEED so the tracker can't begin locked on a harmonic.
///   3. A slew-limited tracker (real HR walks gradually; a harmonic teleports) + sub-harmonic snap.
///   4. Two-pass multi-scale: a long-window anchor (mostly true) + short-window infill gated to agree
///      with the anchor (coverage with the anchor's truth filtering false positives).
enum Heartbeat {

    // Tuning — mirrors the Python constants exactly.
    static let minBPM = 40.0
    static let maxBPM = 120.0
    static let trustBar = 0.40
    static let maxSlewBPMPerS = 0.5
    static let harmonicTol = 0.12
    static let anchorWindowS = 120.0
    static let infillWindowS = 15.0
    static let infillTolBPM = 6.0

    /// One tracked point: minutes from start, the bpm, and the autocorrelation confidence [0…1].
    struct Point: Equatable { let minute: Double; let bpm: Double; let confidence: Double }

    struct Track: Equatable {
        let points: [Point]
        var isEmpty: Bool { points.isEmpty }
        var medianBPM: Double? { points.isEmpty ? nil : Heartbeat.median(points.map(\.bpm)) }
        var meanConfidence: Double? {
            points.isEmpty ? nil : points.map(\.confidence).reduce(0, +) / Double(points.count)
        }
    }

    /// Analyze sorted windows. Returns an empty Track when the envelope is absent/too slow or no
    /// confident anchor forms (the GUESSED case).
    static func analyze(_ windows: [SensorWindow], envelopeHz: Double = SomnyaConfig.accelEnvelopeHz) -> Track {
        let hz = envelopeHz
        // Nyquist: need the envelope fast enough to resolve maxBPM (need ≥ 2× its frequency).
        guard hz >= maxBPM / 60.0 * 2 else { return Track(points: []) }
        // The exact Butterworth band-pass coefficients are computed for the 32 Hz envelope; older
        // recordings (8 Hz) can't use them, so we report no track rather than a mis-filtered guess.
        // The current build always records at 32 Hz, so this only excludes legacy data.
        guard abs(hz - 32.0) < 0.5 else { return Track(points: []) }

        // Concatenate per-window accel envelopes into one stream + a parallel minute timeline.
        var stream: [Double] = []
        var times: [Double] = []
        let mins = SleepOnset.minutesFromStart(windows)  // reuse the shared elapsed-minutes mapping
        for (i, w) in windows.enumerated() {
            guard let env = w.accelEnvelope, !env.isEmpty else { continue }
            stream.append(contentsOf: env)
            times.append(contentsOf: Array(repeating: mins[i], count: env.count))
        }
        guard !stream.isEmpty else { return Track(points: []) }

        let band = bandpassBPM(stream, hz: hz, lowBPM: minBPM, highBPM: maxBPM)

        // PASS 1 — anchor, seeded from the night-wide median fundamental.
        let seed = globalSeed(band, hz: hz, winS: anchorWindowS)
        let anchor = anchorTrack(band, times: times, hz: hz, winS: anchorWindowS, seed: seed)
        guard anchor.count >= 1 else { return Track(points: []) }
        if anchor.count == 1 { return Track(points: anchor) }  // nothing to interpolate against

        let amins = anchor.map(\.minute)
        let arates = anchor.map(\.bpm)

        // PASS 2 — infill from short windows, gated by agreement with the interpolated anchor.
        var infill: [Point] = []
        let n = Int(infillWindowS * hz)
        if n >= 4 && band.count >= n {
            var start = 0
            while start + n <= band.count {
                let minute = times[start + n / 2]
                let expected = interp(minute, xs: amins, ys: arates)
                var best: Point?
                for (b, c) in allPeaks(Array(band[start..<start + n]), hz: hz) where c >= trustBar {
                    for cand in [b, b / 2.0, b * 2.0] {  // allow snapping an octave to meet the anchor
                        if cand >= minBPM && cand <= maxBPM && abs(cand - expected) <= infillTolBPM {
                            if best == nil || c > best!.confidence {
                                best = Point(minute: minute, bpm: cand, confidence: c)
                            }
                            break
                        }
                    }
                }
                if let b = best { infill.append(b) }
                start += n
            }
        }

        // Merge anchor + infill; drop infill points near-coincident with an anchor minute; sort by time.
        var merged = anchor
        var occupied = amins
        let dedup = infillWindowS / 60.0
        for p in infill where occupied.allSatisfy({ abs(p.minute - $0) > dedup }) {
            merged.append(p)
            occupied.append(p.minute)
        }
        merged.sort { $0.minute < $1.minute }
        return Track(points: merged)
    }

    // MARK: - Slew-limited anchor track

    private static func anchorTrack(_ band: [Double], times: [Double], hz: Double,
                                    winS: Double, seed: Double?) -> [Point] {
        let n = Int(winS * hz)
        guard n >= 4, band.count >= n else { return [] }
        var out: [Point] = []
        var cur = seed
        var lastMin: Double?
        var start = 0
        while start + n <= band.count {
            defer { start += n }
            let minute = times[start + n / 2]
            let peaks = allPeaks(Array(band[start..<start + n]), hz: hz)
            let cands = peaks.filter { $0.1 >= trustBar && $0.0 >= minBPM && $0.0 <= maxBPM }
            guard !cands.isEmpty else { continue }

            guard let curVal = cur else {
                // No seed — fall back to the lowest of the near-strongest peaks.
                let top = cands[0].1
                let strong = cands.filter { $0.1 >= top * 0.8 }.map(\.0)
                let v = strong.min() ?? cands[0].0
                cur = v; lastMin = minute
                out.append(Point(minute: minute, bpm: v, confidence: cands[0].1))
                continue
            }

            let budget: Double
            if lastMin == nil {
                budget = infillTolBPM  // first read after a global seed: land within infill tolerance
            } else {
                budget = maxSlewBPMPerS * max(1.0, (minute - lastMin!) * 60.0)
            }

            var expanded = cands
            for (b, c) in cands
            where abs(b / curVal - 2.0) < harmonicTol * 2 && abs(b / 2 - curVal) < abs(b - curVal) {
                expanded.append((b / 2.0, c))  // snap a ~2x harmonic down to the fundamental
            }
            let within = expanded.filter { abs($0.0 - curVal) <= budget }
            guard !within.isEmpty else { continue }  // nothing plausible — coast, don't force a point
            let pick = within.min { a, b in
                let da = abs(a.0 - curVal), db = abs(b.0 - curVal)
                return da != db ? da < db : a.1 > b.1
            }!
            cur = 0.7 * curVal + 0.3 * pick.0  // gentle smoothing toward the accepted candidate
            lastMin = minute
            out.append(Point(minute: minute, bpm: cur!, confidence: pick.1))
        }
        return out
    }

    /// Robust starting HR: the median of each long window's best fundamental across the whole night.
    private static func globalSeed(_ band: [Double], hz: Double, winS: Double) -> Double? {
        let n = Int(winS * hz)
        guard n >= 4, band.count >= n else { return nil }
        var fundamentals: [Double] = []
        var start = 0
        while start + n <= band.count {
            defer { start += n }
            let peaks = allPeaks(Array(band[start..<start + n]), hz: hz)
                .filter { $0.1 >= trustBar && $0.0 >= minBPM && $0.0 <= maxBPM }
            guard !peaks.isEmpty else { continue }
            let top = peaks[0].1
            let strong = peaks.filter { $0.1 >= top * 0.8 }.map(\.0)
            if let lo = strong.min() { fundamentals.append(lo) }
        }
        return fundamentals.isEmpty ? nil : median(fundamentals)
    }

    /// Every interior local-max of the heart-band autocorrelation as (bpm, corr), strongest first.
    static func allPeaks(_ x: [Double], hz: Double, minConf: Double = 0.30) -> [(Double, Double)] {
        let n = x.count
        guard n > 4 else { return [] }
        let mean = x.reduce(0, +) / Double(n)
        let xc = x.map { $0 - mean }
        let energy = xc.reduce(0) { $0 + $1 * $1 }
        guard energy > 1e-12 else { return [] }
        let minLag = Int((60.0 / maxBPM) * hz)
        let maxLag = min(n - 1, Int((60.0 / minBPM) * hz))
        guard maxLag - minLag >= 2, minLag >= 1 else { return [] }
        var corr = [Double](repeating: 0, count: maxLag - minLag + 1)
        for lag in minLag...maxLag {
            var s = 0.0
            for i in 0..<(n - lag) { s += xc[i] * xc[i + lag] }
            corr[lag - minLag] = s / energy
        }
        var peaks: [(Double, Double)] = []
        for i in 1..<(corr.count - 1)
        where corr[i] > corr[i - 1] && corr[i] >= corr[i + 1] && corr[i] >= minConf {
            let bpm = 60.0 / (Double(minLag + i) / hz)
            peaks.append((bpm, corr[i]))
        }
        peaks.sort { $0.1 > $1.1 }
        return peaks
    }

    // MARK: - DSP: 4th-order Butterworth band-pass, zero-phase (filtfilt)

    // EXACT scipy coefficients for butter(4, [lo, hi], btype="band") at our fixed config (32 Hz envelope,
    // 40–120 bpm). A 4th-order BAND-pass is an order-8 transfer function → 9 taps. Hardcoding scipy's
    // own b/a makes the Swift filter identical to Python's (no hand-derived DSP to get wrong); valid only
    // for this band+rate, which is exactly what the heartbeat detector uses (SomnyaConfig.accelEnvelopeHz).
    private static let butterB: [Double] = [
        0.00021313872697507858, 0.0, -0.0008525549079003143, 0.0, 0.0012788323618504716,
        0.0, -0.0008525549079003143, 0.0, 0.00021313872697507858,
    ]
    private static let butterA: [Double] = [
        1.0, -7.128478851637904, 22.41882265640197, -40.62891245342927, 46.40780141204814,
        -34.213335029764785, 15.899132368332243, -4.258400480176443, 0.5033753607417043,
    ]

    /// Zero-phase band-pass via scipy's exact Butterworth coefficients + filtfilt (forward/backward with
    /// odd-reflection edge padding, matching scipy's default). Identical to Python `_bandpass_bpm` for the
    /// 40–120 bpm @ 32 Hz heart band. Falls back to mean-removed signal off that config or when too short.
    static func bandpassBPM(_ x: [Double], hz: Double, lowBPM: Double, highBPM: Double) -> [Double] {
        let mean = x.reduce(0, +) / Double(max(1, x.count))
        let centered = x.map { $0 - mean }
        // The hardcoded coefficients are only valid for the heart band at the standard envelope rate.
        guard abs(hz - 32.0) < 0.5, abs(lowBPM - 40) < 0.5, abs(highBPM - 120) < 0.5,
              centered.count > 25 else { return centered }
        return filtfilt(butterB, butterA, centered)
    }

    /// scipy-style filtfilt: odd-reflection pad (padlen = 3·(ntaps−1)), forward IIR, reverse, forward IIR
    /// again, reverse, then strip the padding. Zero phase, matches scipy.signal.filtfilt defaults.
    private static func filtfilt(_ b: [Double], _ a: [Double], _ x: [Double]) -> [Double] {
        let ntaps = max(b.count, a.count)
        let padlen = 3 * (ntaps - 1)
        guard x.count > padlen else { return x }
        // Odd reflection: 2·x[0] − x[padlen..1] on the left, 2·x[n-1] − x[n-2..n-1-padlen] on the right.
        var ext = [Double]()
        ext.reserveCapacity(x.count + 2 * padlen)
        for i in stride(from: padlen, to: 0, by: -1) { ext.append(2 * x[0] - x[i]) }
        ext.append(contentsOf: x)
        let n = x.count
        for i in 2...(padlen + 1) { ext.append(2 * x[n - 1] - x[n - i]) }

        var y = lfilter(b, a, ext)
        y.reverse()
        y = lfilter(b, a, y)
        y.reverse()
        return Array(y[padlen..<(padlen + n)])
    }

    /// Direct-form-II transposed IIR filter (scipy.signal.lfilter), assuming a[0] == 1.
    private static func lfilter(_ b: [Double], _ a: [Double], _ x: [Double]) -> [Double] {
        let n = max(b.count, a.count)
        var bb = b, aa = a
        while bb.count < n { bb.append(0) }
        while aa.count < n { aa.append(0) }
        var z = [Double](repeating: 0, count: n - 1)  // filter state
        var out = [Double](repeating: 0, count: x.count)
        for i in 0..<x.count {
            let xn = x[i]
            let yn = bb[0] * xn + (z.isEmpty ? 0 : z[0])
            for j in 0..<(n - 2) {
                z[j] = bb[j + 1] * xn + z[j + 1] - aa[j + 1] * yn
            }
            if n >= 2 { z[n - 2] = bb[n - 1] * xn - aa[n - 1] * yn }
            out[i] = yn
        }
        return out
    }

    // MARK: - small helpers

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        let m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }

    /// Linear interpolation of y at x given sorted xs (clamps to endpoints), like numpy.interp.
    private static func interp(_ x: Double, xs: [Double], ys: [Double]) -> Double {
        guard let first = xs.first, let last = xs.last else { return 0 }
        if x <= first { return ys.first! }
        if x >= last { return ys.last! }
        var i = 0
        while i < xs.count - 1 && xs[i + 1] < x { i += 1 }
        let x0 = xs[i], x1 = xs[i + 1], y0 = ys[i], y1 = ys[i + 1]
        let t = (x1 - x0) == 0 ? 0 : (x - x0) / (x1 - x0)
        return y0 + t * (y1 - y0)
    }
}
