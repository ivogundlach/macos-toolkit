import SwiftUI
import AppKit

// MARK: - Nutrient Tracker design system

/// A compact, calm visual vocabulary for the health workspace. Teal belongs to
/// navigation and primary actions; coverage, caution, and risk keep independent
/// semantic colors so the interface never turns health status into decoration.
enum HealthUI {
    static let accent = adaptive(
        light: NSColor(srgbRed: 0.02, green: 0.39, blue: 0.36, alpha: 1),
        dark: NSColor(srgbRed: 0.31, green: 0.82, blue: 0.74, alpha: 1))
    static let positive = adaptive(
        light: NSColor(srgbRed: 0.08, green: 0.43, blue: 0.21, alpha: 1),
        dark: NSColor(srgbRed: 0.40, green: 0.82, blue: 0.52, alpha: 1))
    static let warning = adaptive(
        light: NSColor(srgbRed: 0.61, green: 0.34, blue: 0.00, alpha: 1),
        dark: NSColor(srgbRed: 1.00, green: 0.70, blue: 0.28, alpha: 1))
    static let negative = adaptive(
        light: NSColor(srgbRed: 0.70, green: 0.10, blue: 0.13, alpha: 1),
        dark: NSColor(srgbRed: 1.00, green: 0.45, blue: 0.47, alpha: 1))
    static let gi = adaptive(
        light: NSColor(srgbRed: 0.53, green: 0.23, blue: 0.62, alpha: 1),
        dark: NSColor(srgbRed: 0.82, green: 0.59, blue: 0.92, alpha: 1))

    static let pageInset: CGFloat = 18
    static let regionSpacing: CGFloat = 14
    static let componentSpacing: CGFloat = 10
    static let microSpacing: CGFloat = 6
    static let controlRadius: CGFloat = 8
    static let rowRadius: CGFloat = 9
    static let cardRadius: CGFloat = 12
    static let regionRadius: CGFloat = 15

    static let accentSoft = accent.opacity(0.12)

    // Liquid Glass. Cards and regions only — rows and controls stay on the flat
    // `surface` fills below, because they sit *inside* those cards and glass on
    // glass reads as neither.
    static let cardGlass: Glass = .regular
    static let interactiveGlass: Glass = .regular.interactive()

    static let surface = Color.primary.opacity(0.045)
    static let surfaceRaised = Color.primary.opacity(0.065)
    static let groupedSurface = Color.primary.opacity(0.028)
    static let hairline = Color.primary.opacity(0.085)
    static let workspace = Color(nsColor: .windowBackgroundColor)
    static let sidebar = Color(nsColor: .underPageBackgroundColor)

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        let dynamic = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
        return Color(nsColor: dynamic)
    }
}

struct HealthSectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.75)
            .foregroundStyle(.secondary)
    }
}

struct HealthPageHeader<Trailing: View>: View {
    let eyebrow: String
    let title: String
    let summary: String
    let systemImage: String
    var tint: Color = HealthUI.accent
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                identity
                Spacer(minLength: 12)
                trailing()
            }
            VStack(alignment: .leading, spacing: 10) {
                identity
                trailing()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .refractiveGlass(cornerRadius: HealthUI.regionRadius)
    }

    private var identity: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: HealthUI.controlRadius, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.85), tint],
                                         startPoint: .bottomLeading, endPoint: .topTrailing))
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(eyebrow.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.75)
                    .foregroundStyle(tint)
                Text(title).font(.title2.weight(.semibold))
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension HealthPageHeader where Trailing == EmptyView {
    init(eyebrow: String, title: String, summary: String, systemImage: String,
         tint: Color = HealthUI.accent) {
        self.init(eyebrow: eyebrow, title: title, summary: summary,
                  systemImage: systemImage, tint: tint, trailing: { EmptyView() })
    }
}

/// Sidebar/header hue per section; coverage status colors keep their
/// semantic meaning inside the screens.
extension AppSection {
    var tint: Color {
        switch self {
        case .longterm: return Color(red: 0.09, green: 0.48, blue: 0.44)
        case .trends: return Color(red: 0.22, green: 0.45, blue: 0.82)
        case .gi: return Color(red: 0.56, green: 0.32, blue: 0.68)
        case .today: return Color(red: 0.22, green: 0.58, blue: 0.32)
        case .gaps: return Color(red: 0.85, green: 0.52, blue: 0.14)
        case .settings: return Color(red: 0.48, green: 0.52, blue: 0.58)
        }
    }
}

struct HealthPanel<Content: View>: View {
    let title: String?
    let subtitle: String?
    let systemImage: String?
    let content: Content

    init(title: String? = nil, subtitle: String? = nil, systemImage: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HealthUI.componentSpacing) {
            if let title {
                HStack(alignment: .top, spacing: 8) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 21, height: 21)
                            .background(RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                .fill(LinearGradient(colors: [HealthUI.accent.opacity(0.85), HealthUI.accent],
                                                     startPoint: .bottomLeading, endPoint: .topTrailing)))
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline)
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .refractiveGlass(cornerRadius: HealthUI.cardRadius)
    }
}

struct HealthStatusPill: View {
    let text: String
    let systemImage: String
    var color: Color = .secondary

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.12)))
            .overlay(Capsule().strokeBorder(color.opacity(0.22), lineWidth: 1))
            .accessibilityLabel(text)
    }
}

struct HealthMetric: View {
    let label: String
    let value: String
    let detail: String
    let systemImage: String
    var color: Color = HealthUI.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .refractiveInset(cornerRadius: HealthUI.rowRadius)
        .accessibilityElement(children: .combine)
    }
}

struct HealthNotice: View {
    let title: String
    let message: String
    let systemImage: String
    var color: Color = HealthUI.accent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: HealthUI.rowRadius, style: .continuous)
            .fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: HealthUI.rowRadius, style: .continuous)
            .strokeBorder(color.opacity(0.18), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

struct HealthEmptyState: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(HealthUI.accent)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
        }
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct HealthPrimaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
            .background(RoundedRectangle(cornerRadius: HealthUI.controlRadius, style: .continuous)
                .fill(HealthUI.accent.opacity(!isEnabled ? 0.38 : (configuration.isPressed ? 0.76 : 1))))
            .contentShape(RoundedRectangle(cornerRadius: HealthUI.controlRadius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.7)
    }
}

struct HealthSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: HealthUI.controlRadius, style: .continuous)
                .fill(configuration.isPressed ? HealthUI.surfaceRaised : HealthUI.surface))
            .contentShape(RoundedRectangle(cornerRadius: HealthUI.controlRadius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.48)
    }
}

/// Compact coverage bar. The surrounding row always supplies an icon and text
/// status; the fill color is reinforcement rather than the only signal.
struct GapBar: View {
    let pct: Double
    var tint: Color? = nil
    var accessibilityName: String = "Coverage"

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.secondary.opacity(0.16))
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color)
                    .frame(width: max(2, geo.size.width * min(1, max(0, pct))))
            }
        }
        .frame(height: 7)
        .accessibilityElement()
        .accessibilityLabel(accessibilityName)
        .accessibilityValue("\(Int(max(0, pct) * 100)) percent")
    }

    private var color: Color {
        if let tint { return tint }
        if pct >= 1 { return HealthUI.positive }
        if pct >= 0.7 { return HealthUI.warning }
        return HealthUI.negative
    }
}

func fmt(_ value: Double, _ unit: String) -> String {
    let number: String
    if value >= 100 { number = String(format: "%.0f", value) }
    else if value >= 10 { number = String(format: "%.1f", value) }
    else { number = String(format: "%.2f", value) }
    return "\(number) \(unit)"
}

struct MagnitudeTag: View {
    let text: String?

    var body: some View {
        if let text {
            Label(text, systemImage: icon(for: text))
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .foregroundStyle(color(for: text))
                .background(Capsule().fill(color(for: text).opacity(0.12)))
                .overlay(Capsule().strokeBorder(color(for: text).opacity(0.2), lineWidth: 1))
        }
    }

    private func icon(for text: String) -> String {
        text.lowercased().contains("severe") ? "exclamationmark.triangle.fill" : "exclamationmark.circle"
    }

    private func color(for text: String) -> Color {
        text.lowercased().contains("severe") ? HealthUI.negative : HealthUI.warning
    }
}
