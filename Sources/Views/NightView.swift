import SwiftUI
import SwiftData

/// One night, told in the order it happened: getting to sleep, staying asleep, waking up, then the
/// body. Each number sits beside what's usual for you (your previous nights), because a number
/// alone says little. Estimated values carry the half dot and are coloured by confidence; measured
/// ones use plain text, so colour only ever means trust.
struct NightView: View {
    let session: SleepSession
    @Environment(\.modelContext) private var modelContext
    @State private var night: NightReport?
    @State private var before: [NightReport] = []

    var body: some View {
        ScrollView {
            if let night {
                content(night)
            } else {
                ProgressView().tint(Theme.text2).padding(.top, 120)
            }
        }
        .background(Theme.base.ignoresSafeArea())
        .navigationTitle(session.startTime.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.base, for: .navigationBar)
        .task(id: session.persistentModelID) {
            // Created off the main actor, or it would compute on the main thread (see RootView).
            let container = modelContext.container, id = session.persistentModelID
            if let r = try? await Task.detached(operation: {
                try await NightReporter(modelContainer: container).reports(for: id)
            }).value {
                night = r.night
                before = r.before
            }
        }
    }

    private func content(_ n: NightReport) -> some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            WeekStrip(nights: Array(before.prefix(6).reversed()) + [n])
            hero(n)
            ForEach(Chapter.allCases, id: \.self) { chapter in
                let cards = Measure.all.filter { $0.chapter == chapter && !$0.inHeader }
                if !cards.isEmpty {
                    Text(chapter.rawValue)
                        .font(Theme.font(.subheadline, weight: .semibold))
                        .foregroundStyle(Theme.text2)
                        .padding(.top, 14)
                    ForEach(cards, id: \.label) { m in
                        MeasureCard(measure: m, night: n, before: before)
                    }
                    if chapter == .body { breathingCard }
                }
            }
            NavigationLink {
                SessionDetailView(session: session)
            } label: {
                HStack {
                    Text("In-depth view").font(Theme.font(.body, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.text3)
                }
                .foregroundStyle(Theme.text1)
                .padding(Theme.cardPadding)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 32)
    }

    /// The whole night at a glance: how long asleep, when it started and ended, its shape, and
    /// what was different. Everything below it is detail.
    private func hero(_ n: NightReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Asleep").font(Theme.font(.subheadline)).foregroundStyle(Theme.text2)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(n.asleepMinutes.map(Fmt.duration) ?? "—")
                    .font(Theme.font(.largeTitle, weight: .bold))
                    .foregroundStyle(n.asleepMinutes == nil ? Theme.text3 : Theme.confidence(n.asleepConfidence))
                if n.asleepMinutes != nil { EstimatedMark(confidence: n.asleepConfidence) }
            }
            Text(subline(n)).font(Theme.font(.subheadline)).foregroundStyle(Theme.text2)
            times(n).padding(.top, 10)
            NightStrip(night: n).padding(.top, 4)
            Text(Measure.differenceSentence(night: n, before: before))
                .font(Theme.font(.body))
                .foregroundStyle(Theme.text1)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.cardPadding)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }

    private func times(_ n: NightReport) -> some View {
        HStack(alignment: .top) {
            TimeColumn(label: "In bed", time: n.start, confidence: nil)
            Spacer()
            TimeColumn(label: "Fell asleep", time: n.settleMinutes.map { n.start.addingTimeInterval($0 * 60) },
                       confidence: n.settleConfidence)
            Spacer()
            TimeColumn(label: "Woke up", time: n.wake.map { n.start.addingTimeInterval($0.minute * 60) },
                       confidence: n.wake?.confidence)
        }
    }

    private func subline(_ n: NightReport) -> String {
        var s = "of \(Fmt.duration(n.inBedMinutes)) in bed"
        if let usual = Measure.usual(before.compactMap(\.asleepMinutes)) { s += " · usually \(Fmt.duration(usual))" }
        return s
    }

    /// The empty-bed control (31 Oct) scored the same breathing confidence as real nights, so
    /// nothing the microphone reports about breathing can be shown as measured.
    private var breathingCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Breathing").font(Theme.font(.subheadline)).foregroundStyle(Theme.text2)
            Text("Not measured").font(Theme.font(.title3, weight: .semibold)).foregroundStyle(Theme.text3)
            Text("The microphone can't yet tell your breathing from an empty room.")
                .font(Theme.font(.footnote)).foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.cardPadding)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
}

// MARK: - Measures

enum Chapter: String, CaseIterable {
    case gettingToSleep = "Getting to sleep"
    case stayingAsleep = "Staying asleep"
    case wakingUp = "Waking up"
    case body = "Your body"
}

/// One row of the night: how to read it from a report, how to say it, and how big a difference
/// from usual is worth pointing out.
struct Measure {
    let chapter: Chapter
    let label: String
    let value: (NightReport) -> Double?
    /// nil for measured values; the estimate's confidence otherwise.
    let confidence: (NightReport) -> Double?
    let format: (Double, NightReport) -> String
    let formatDelta: (Double) -> String
    /// Words for a positive and a negative difference, as in "12 min later than usual".
    let more: String, less: String
    /// A difference smaller than this reads as a usual night and the card dims.
    let notable: Double
    /// Shown as a time in the header card rather than a card of its own.
    var inHeader = false

    static let all: [Measure] = [
        Measure(chapter: .gettingToSleep, label: "Went to bed",
                value: { Fmt.clockMinutes($0.start) }, confidence: { _ in nil },
                format: { _, n in Fmt.clock(n.start) }, formatDelta: Fmt.duration,
                more: "later", less: "earlier", notable: 20, inHeader: true),
        Measure(chapter: .gettingToSleep, label: "Fell asleep in",
                value: \.settleMinutes, confidence: \.settleConfidence,
                format: { v, _ in Fmt.duration(v) }, formatDelta: Fmt.duration,
                more: "slower", less: "faster", notable: 5),
        Measure(chapter: .stayingAsleep, label: "Longest still stretch",
                value: { $0.longestStill?.minutes }, confidence: { _ in nil },
                format: { v, _ in Fmt.duration(v) }, formatDelta: Fmt.duration,
                more: "longer", less: "shorter", notable: 20),
        Measure(chapter: .stayingAsleep, label: "Movements",
                value: { Double($0.movements.count) }, confidence: { _ in nil },
                format: { v, n in "\(Int(v)) · \(n.largeMovements) large" },
                formatDelta: { "\(Int($0.rounded()))" },
                more: "more", less: "fewer", notable: 8),
        Measure(chapter: .wakingUp, label: "Woke up",
                value: { n in n.wake.map { Fmt.clockMinutes(n.start) + $0.minute } },
                confidence: { $0.wake?.confidence },
                format: { _, n in n.wake.map { Fmt.clock(n.start.addingTimeInterval($0.minute * 60)) } ?? "—" },
                formatDelta: Fmt.duration, more: "later", less: "earlier", notable: 20, inHeader: true),
        Measure(chapter: .body, label: "Heart rate",
                value: \.heartBPM, confidence: { $0.heartConfidence },
                format: { v, _ in "\(Int(v.rounded())) bpm" },
                formatDelta: { "\(Int($0.rounded())) bpm" },
                more: "higher", less: "lower", notable: 4),
    ]

    /// Usual needs a few nights behind it, or one odd night sets the bar.
    static func usual(_ values: [Double]) -> Double? {
        values.count >= 3 ? values.reduce(0, +) / Double(values.count) : nil
    }

    func usual(_ before: [NightReport]) -> Double? { Measure.usual(before.compactMap(value)) }

    func delta(_ n: NightReport, _ before: [NightReport]) -> Double? {
        guard let v = value(n), let u = usual(before) else { return nil }
        return v - u
    }

    func deltaText(_ d: Double) -> String {
        "\(formatDelta(abs(d))) \(d >= 0 ? more : less)"
    }

    /// The three biggest differences from usual, in words, or a plain note that it was a usual night.
    static func differenceSentence(night: NightReport, before: [NightReport]) -> String {
        let notable = all.compactMap { m -> (Measure, Double)? in
            guard let d = m.delta(night, before), abs(d) >= m.notable else { return nil }
            return (m, d)
        }
        .sorted { abs($0.1) / $0.0.notable > abs($1.1) / $1.0.notable }
        .prefix(3)
        if before.count < 3 { return "A few more nights and this will compare to your usual." }
        guard !notable.isEmpty else { return "Close to your usual night." }
        let parts = notable.map { m, d in "\(m.shortLabel) \(m.deltaText(d))" }
        let joined = parts.count == 1 ? parts[0]
            : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        return joined.prefix(1).uppercased() + joined.dropFirst() + " than usual."
    }

    private var shortLabel: String {
        switch label {
        case "Went to bed": return "went to bed"
        case "Fell asleep in": return "fell asleep"
        case "Longest still stretch": return "longest still stretch"
        case "Movements": return "moved"
        case "Woke up": return "woke up"
        default: return label.lowercased()
        }
    }
}

// MARK: - Pieces

private struct MeasureCard: View {
    let measure: Measure
    let night: NightReport
    let before: [NightReport]

    var body: some View {
        let v = measure.value(night)
        let conf = measure.confidence(night)
        let d = measure.delta(night, before)
        let dim = d.map { abs($0) < measure.notable } ?? true
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(measure.label).font(Theme.font(.subheadline)).foregroundStyle(Theme.text2)
                HStack(spacing: 6) {
                    Text(v.map { measure.format($0, night) } ?? "—")
                        .font(Theme.font(.title3, weight: .semibold))
                        .foregroundStyle(v == nil ? Theme.text3 : conf.map(Theme.confidence) ?? Theme.text1)
                    if v != nil, let conf { EstimatedMark(confidence: conf) }
                }
                if let d {
                    Text(dim ? "about usual" : measure.deltaText(d))
                        .font(Theme.font(.footnote)).foregroundStyle(Theme.text2)
                }
            }
            Spacer()
            Spark(values: (before.reversed() + [night]).map(measure.value),
                  usual: measure.usual(before), minSpan: measure.notable * 2)
                .frame(width: 92, height: 34)
        }
        .padding(Theme.cardPadding)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .opacity(dim ? 0.72 : 1)
    }
}

/// The half-filled dot that marks an estimate, in the estimate's confidence colour.
private struct EstimatedMark: View {
    let confidence: Double
    var body: some View {
        let c = Theme.confidence(confidence)
        Circle().stroke(c, lineWidth: 1.5)
            .overlay(Circle().trim(from: 0.25, to: 0.75).fill(c).rotationEffect(.degrees(0)))
            .frame(width: 9, height: 9)
            .accessibilityLabel("estimated")
    }
}

/// The last nights as a smooth line, this night as the dot at its end.
/// Each point is one real night. The scale never shrinks below `minSpan` (twice the difference
/// worth pointing out), so nights within the usual range draw nearly flat instead of being
/// stretched into waves; the dashed line is usual.
private struct Spark: View {
    let values: [Double?]
    let usual: Double?
    let minSpan: Double
    var body: some View {
        Canvas { ctx, size in
            let pts = values.enumerated().compactMap { i, v in v.map { (Double(i), $0) } }
            guard pts.count >= 2, let lo0 = pts.map(\.1).min(), let hi0 = pts.map(\.1).max() else { return }
            let pad = max(0, minSpan - (hi0 - lo0)) / 2
            let lo = lo0 - pad, span = max(hi0 - lo0, minSpan)
            let xMax = Double(max(values.count - 1, 1))
            func y(_ v: Double) -> CGFloat { size.height - 4 - (v - lo) / span * (size.height - 8) }
            if let usual {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y(usual)))
                line.addLine(to: CGPoint(x: size.width, y: y(usual)))
                ctx.stroke(line, with: .color(Theme.stroke), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            // Inset by the end dot's radius so it isn't clipped at the edge.
            let cg = pts.map { CGPoint(x: 3 + $0.0 / xMax * (size.width - 6), y: y($0.1)) }
            ctx.stroke(Smooth.path(cg), with: .color(Theme.text3), lineWidth: 1.5)
            for p in cg.dropLast() {
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)),
                         with: .color(Theme.text3))
            }
            if values.last! != nil, let p = cg.last {
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)),
                         with: .color(Theme.accent))
            }
        }
    }
}

/// Each recent night as a ring: how much of the time in bed was asleep.
private struct WeekStrip: View {
    let nights: [NightReport]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(nights.enumerated()), id: \.offset) { i, n in
                let isThis = i == nights.count - 1
                VStack(spacing: 6) {
                    ZStack {
                        Circle().stroke(Theme.raised, lineWidth: 4)
                        Circle()
                            .trim(from: 0, to: (n.asleepMinutes ?? 0) / max(n.inBedMinutes, 1))
                            .stroke(isThis ? Theme.accent : Theme.text3,
                                    style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 30, height: 30)
                    Text(n.start.formatted(.dateTime.weekday(.narrow)))
                        .font(Theme.font(.caption2, weight: isThis ? .bold : .regular))
                        .foregroundStyle(isThis ? Theme.text1 : Theme.text3)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
    }
}

/// The night from going to bed to the end of the recording: the asleep block fading in at onset,
/// the longest still stretch as the brightest part, and each movement as a dot.
private struct NightStrip: View {
    let night: NightReport
    var body: some View {
        VStack(spacing: 6) {
            Canvas { ctx, size in
                let total = max(night.inBedMinutes, 1)
                func x(_ m: Double) -> CGFloat { CGFloat(min(max(m / total, 0), 1)) * (size.width - 6) + 3 }
                let barY: CGFloat = 14, barH: CGFloat = 18
                let bar = CGRect(x: 3, y: barY, width: size.width - 6, height: barH)
                ctx.fill(Path(roundedRect: bar, cornerRadius: barH / 2), with: .color(Theme.raised))
                if let s = night.settleMinutes {
                    let e = night.wake?.minute ?? total
                    let r = CGRect(x: x(s), y: barY, width: max(x(e) - x(s), 2), height: barH)
                    ctx.fill(Path(roundedRect: r, cornerRadius: barH / 2),
                             with: .linearGradient(
                                Gradient(colors: [Theme.accent.opacity(0.15), Theme.accent.opacity(0.55)]),
                                startPoint: CGPoint(x: r.minX, y: 0),
                                endPoint: CGPoint(x: r.minX + min(r.width, 40), y: 0)))
                }
                if let still = night.longestStill {
                    let r = CGRect(x: x(still.endMinute - still.minutes), y: barY,
                                   width: max(x(still.endMinute) - x(still.endMinute - still.minutes), 2),
                                   height: barH)
                    ctx.fill(Path(roundedRect: r, cornerRadius: barH / 2), with: .color(Theme.accent))
                }
                for m in night.movements {
                    let d: CGFloat = m.large ? 6 : 3.5
                    ctx.fill(Path(ellipseIn: CGRect(x: x(m.minute) - d / 2, y: 4 - d / 2 + 2, width: d, height: d)),
                             with: .color(m.large ? Theme.text1 : Theme.text3))
                }
            }
            .frame(height: 36)
        }
    }
}

private struct TimeColumn: View {
    let label: String
    let time: Date?
    /// nil when measured.
    let confidence: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Theme.font(.caption)).foregroundStyle(Theme.text2)
            HStack(spacing: 5) {
                Text(time.map(Fmt.clock) ?? "—")
                    .font(Theme.font(.headline, weight: .semibold))
                    .foregroundStyle(time == nil ? Theme.text3 : confidence.map(Theme.confidence) ?? Theme.text1)
                if time != nil, let confidence { EstimatedMark(confidence: confidence) }
            }
        }
    }
}

// MARK: - Shared drawing and formatting

enum Smooth {
    /// A monotone cubic (Fritsch–Carlson) through every point: smooth like the icon's waves, but
    /// never rising above or dipping below its neighbours. Catmull-Rom overshot, drawing peaks
    /// between nights that no night had.
    static func path(_ p: [CGPoint]) -> Path {
        var path = Path()
        guard let first = p.first else { return path }
        path.move(to: first)
        let n = p.count
        guard n > 2 else { if n == 2 { path.addLine(to: p[1]) }; return path }
        let d = (0..<(n - 1)).map { (p[$0 + 1].y - p[$0].y) / (p[$0 + 1].x - p[$0].x) }
        var m = [CGFloat](repeating: 0, count: n)
        m[0] = d[0]; m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
        for i in 0..<(n - 1) where d[i] == 0 { m[i] = 0; m[i + 1] = 0 }
        for i in 0..<(n - 1) where d[i] != 0 {
            let a = m[i] / d[i], b = m[i + 1] / d[i], h = a * a + b * b
            if h > 9 { let t = 3 / h.squareRoot(); m[i] = t * a * d[i]; m[i + 1] = t * b * d[i] }
        }
        for i in 0..<(n - 1) {
            let dx = (p[i + 1].x - p[i].x) / 3
            path.addCurve(to: p[i + 1],
                          control1: CGPoint(x: p[i].x + dx, y: p[i].y + m[i] * dx),
                          control2: CGPoint(x: p[i + 1].x - dx, y: p[i + 1].y - m[i + 1] * dx))
        }
        return path
    }
}

enum Fmt {
    static func duration(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return m < 60 ? "\(m) min" : "\(m / 60)h \(String(format: "%02d", m % 60))m"
    }

    static func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    /// Minutes past the evening boundary, so 23:30 and 00:30 average to midnight, not noon.
    static func clockMinutes(_ d: Date) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        let m = Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
        let boundary = Double(SomnyaConfig.dayBoundaryHour * 60)
        return m >= boundary ? m - boundary : m + 24 * 60 - boundary
    }
}
