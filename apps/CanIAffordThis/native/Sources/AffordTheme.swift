import SwiftUI

enum AffordTheme {
    static let spacing4: CGFloat = 4
    static let spacing8: CGFloat = 8
    static let spacing12: CGFloat = 12
    static let spacing16: CGFloat = 16
    static let spacing24: CGFloat = 24
    static let cardRadius: CGFloat = 10
    static let accent = Color(red: 0.13, green: 0.61, blue: 0.43)
    static let caution = Color(red: 0.92, green: 0.55, blue: 0.20)
    static let danger = Color(red: 0.86, green: 0.28, blue: 0.26)

    static let numberFont = Font.system(.title, design: .rounded, weight: .bold).monospacedDigit()
    static let compactNumberFont = Font.system(.title3, design: .rounded, weight: .semibold).monospacedDigit()
    static let kickerFont = Font.caption2.weight(.bold)
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(AffordTheme.spacing16)
            .refractiveGlass(cornerRadius: AffordTheme.cardRadius)
    }
}

struct Kicker: View {
    let text: String
    var color: Color = AffordTheme.accent

    var body: some View {
        Text(text.uppercased())
            .font(AffordTheme.kickerFont)
            .tracking(1.2)
            .foregroundStyle(color)
    }
}
