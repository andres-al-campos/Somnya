import SwiftUI

/// Somnya's design system: the one place that decides how things look.
/// When a view and this file disagree, the view changes. The values were
/// tuned in OKLCH against designs/style-tile.html and are kept as hex here
/// so the two can be compared by eye.
enum Theme {
    // MARK: Ground
    // One hue and chroma, stepped in lightness, so cards read as the same
    // material raised rather than a second colour.
    static let base = Color(hex: 0x061831)
    static let glow = Color(hex: 0x223D81)
    static let card = Color(hex: 0x12243E)
    static let raised = Color(hex: 0x1E314C)
    static let stroke = Color(hex: 0x2A3D5A)

    // MARK: Text
    static let text1 = Color(hex: 0xECF2FC)
    static let text2 = Color(hex: 0x96A6BC)
    static let text3 = Color(hex: 0x53647D)

    // MARK: Accent
    /// Marks, the primary button, selection. Solid, never a gradient. Kept
    /// away from the confidence blue and purple so a selected control never
    /// reads as a trust level.
    static let accent = Color(hex: 0x5772FF)

    // MARK: Confidence
    // Colour means confidence and nothing else: a value's position says what
    // was measured, its colour says how far to trust it. So no other element
    // borrows these four.
    static let confidenceStops: [Color] = [
        Color(hex: 0xF87584),  // don't trust
        Color(hex: 0xAD8DFD),
        Color(hex: 0x36ACFF),
        Color(hex: 0x12C281),  // trust
    ]
    private static let confidenceRGB: [(Double, Double, Double)] = [
        (248, 117, 132), (173, 141, 253), (54, 172, 255), (18, 194, 129),
    ]

    /// The colour for a confidence in 0…1, blended between the stops the
    /// same way the style tile does, so a chart here matches the mockup.
    static func confidence(_ c: Double) -> Color {
        let t = min(max(c, 0), 0.999) * 3
        let i = Int(t), f = t - Double(i)
        let (a, b) = (confidenceRGB[i], confidenceRGB[i + 1])
        return Color(
            red: (a.0 + (b.0 - a.0) * f) / 255,
            green: (a.1 + (b.1 - a.1) * f) / 255,
            blue: (a.2 + (b.2 - a.2) * f) / 255)
    }

    // MARK: Shape and space
    static let cardRadius: CGFloat = 22
    static let cardPadding: CGFloat = 18
    static let gap: CGFloat = 12

    // MARK: Type
    static func font(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .rounded, weight: weight)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}
