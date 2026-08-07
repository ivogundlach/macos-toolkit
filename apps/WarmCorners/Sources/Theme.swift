import SwiftUI

/// Extends the fleet's token pattern (Theme / VitalsTheme / MarketUI) rather than
/// introducing a new design system. "Warm" is the delay: a corner heats up while
/// the pointer rests on it instead of firing the instant it is touched.
enum WarmUI {
    static let page = Color(nsColor: .windowBackgroundColor)
    static let inset = Color(nsColor: .windowBackgroundColor)
    static let border = Color.primary.opacity(0.09)

    static let cardRadius: CGFloat = 12
    static let controlRadius: CGFloat = 8

    // Liquid Glass. Peer surfaces all take the same untinted material so the four
    // cards keep reading as one grid. Armed state is carried in the foreground —
    // the lit glyph and the chosen app — because a hairline stroke washes out
    // against the material's own rim highlight.
    static let cardGlass: Glass = .regular
    static let interactiveGlass: Glass = .regular.interactive()
    /// The countdown floats over arbitrary desktop content, so it gets the
    /// lensing material rather than a flat blur.
    static let indicatorGlass: Glass = .regular

    static let warmStart = Color(red: 1.00, green: 0.70, blue: 0.28)
    static let warmEnd = Color(red: 0.89, green: 0.33, blue: 0.17)
    static let warmGradient = LinearGradient(
        colors: [warmStart, warmEnd], startPoint: .topLeading, endPoint: .bottomTrailing)

    // Static lens cues sit above the native glass substrate and below the glyph.
    // They are deliberately quieter and tighter than the functional progress arc.
    static let indicatorSpecular = LinearGradient(
        colors: [
            Color.white.opacity(0.12),
            Color.white.opacity(0.72),
            Color.white.opacity(0.14),
        ],
        startPoint: .top,
        endPoint: .bottom)
    static let indicatorCaustic = LinearGradient(
        colors: [
            warmStart.opacity(0.10),
            warmEnd.opacity(0.30),
            warmStart.opacity(0.08),
        ],
        startPoint: .leading,
        endPoint: .trailing)
    static let indicatorSpecularWidth: CGFloat = 1.25
    static let indicatorSpecularPadding: CGFloat = 8
    static let indicatorSpecularStart: CGFloat = 0.70
    static let indicatorSpecularEnd: CGFloat = 0.90
    static let indicatorCausticWidth: CGFloat = 1.25
    static let indicatorCausticPadding: CGFloat = 9
    static let indicatorCausticStart: CGFloat = 0.32
    static let indicatorCausticEnd: CGFloat = 0.68

    // The progress path is an orange-tinted glass tube: dark refraction outside,
    // a translucent body, a warmer core, and a quiet inner edge catch.
    static let indicatorMoltenRim = LinearGradient(
        colors: [
            Color(red: 0.49, green: 0.19, blue: 0.08).opacity(0.82),
            Color(red: 0.22, green: 0.07, blue: 0.04).opacity(0.94),
            Color(red: 0.50, green: 0.16, blue: 0.07).opacity(0.72),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing)
    static let indicatorMoltenBody = LinearGradient(
        colors: [
            warmStart.opacity(0.78),
            warmStart.opacity(0.48),
            warmEnd.opacity(0.70),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing)
    static let indicatorMoltenCore = LinearGradient(
        colors: [warmStart.opacity(0.98), warmEnd.opacity(0.92)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing)
    static let indicatorMoltenSpecular = LinearGradient(
        colors: [
            Color.white.opacity(0.78),
            warmStart.opacity(0.70),
            Color.white.opacity(0.24),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing)
    static let indicatorMoltenRimWidth: CGFloat = 8
    static let indicatorMoltenBodyWidth: CGFloat = 7
    static let indicatorMoltenCoreWidth: CGFloat = 5
    static let indicatorMoltenSpecularWidth: CGFloat = 1.05
    static let indicatorMoltenPadding: CGFloat = 4
    static let indicatorMoltenSpecularPadding: CGFloat = 5
    static let indicatorMoltenRimOpacity: Double = 0.78
    static let indicatorMoltenBodyOpacity: Double = 0.94
    static let indicatorMoltenCoreOpacity: Double = 0.94
    static let indicatorMoltenSpecularOpacity: Double = 0.92

    static let title = Font.system(size: 13, weight: .semibold)
    static let label = Font.system(size: 11)
    static let value = Font.system(size: 11, weight: .medium, design: .rounded)
}
