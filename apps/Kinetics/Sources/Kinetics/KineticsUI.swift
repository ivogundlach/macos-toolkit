import SwiftUI

/// Kinetics' small, shared visual vocabulary. Keep styling here so the one
/// module can grow without inventing a second token system.
enum KineticsUI {
    enum Dials {
        static let variance = 4
        static let motion = 3
        static let density = 6
    }

    enum Space {
        static let s4: CGFloat = 4
        static let s8: CGFloat = 8
        static let s12: CGFloat = 12
        static let s16: CGFloat = 16
        static let s24: CGFloat = 24
    }

    static let accent = Color(red: 0.18, green: 0.82, blue: 0.76)
    static let accentBright = Color(red: 0.32, green: 0.91, blue: 0.86)
    static let cyan = Color(red: 0.22, green: 0.71, blue: 0.88)
    static let warning = Color(red: 0.98, green: 0.70, blue: 0.25)
    static let danger = Color(red: 0.97, green: 0.42, blue: 0.40)
    static let success = Color(red: 0.34, green: 0.84, blue: 0.56)

    /// AppKit supplies an appearance-aware neutral surface for both modes.
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .windowBackgroundColor)
    static let hairline = Color.primary.opacity(0.13)

    static let kicker = Font.system(size: 10, weight: .semibold, design: .rounded)
    static let metric = Font.system(size: 28, weight: .semibold, design: .rounded)
    static let monospacedMetric = Font.system(size: 15, weight: .medium, design: .monospaced)

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension View {
    func kineticsPanel() -> some View {
        self
            .padding(KineticsUI.Space.s16)
            .background(KineticsUI.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(KineticsUI.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
