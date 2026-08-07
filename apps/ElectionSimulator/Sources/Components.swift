import SwiftUI

struct PageHeader: View {
    let eyebrow: String
    let title: String
    let detail: String
    let symbol: String
    var tint: Color = Theme.civic

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [tint.opacity(0.85), tint],
                                         startPoint: .bottomLeading, endPoint: .topTrailing))
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(eyebrow.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct StatusPill: View {
    let title: String
    let symbol: String
    var tint: Color = Theme.civic

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.11)))
            .overlay(Capsule().stroke(tint.opacity(0.18), lineWidth: 1))
    }
}

/// Horizontal party composition with a majority marker and a full text alternative.
struct CompositionBar: View {
    let dem: Int
    let rep: Int
    var ind: Int = 0
    let total: Int
    var majorityAt: Int? = nil
    var height: CGFloat = 26

    private var accessibilitySummary: String {
        var parts = ["Democratic \(dem)"]
        if ind > 0 { parts.append("Independent \(ind)") }
        parts.append("Republican \(rep)")
        if let majorityAt { parts.append("majority at \(majorityAt)") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        GeometryReader { geometry in
            let unit = total > 0 ? geometry.size.width / CGFloat(total) : 0
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(Theme.panelStrong)
                HStack(spacing: 0) {
                    Rectangle().fill(Theme.dem).frame(width: unit * CGFloat(dem))
                    Rectangle().fill(Theme.ind).frame(width: unit * CGFloat(ind))
                    Rectangle().fill(Theme.rep).frame(width: unit * CGFloat(rep))
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))

                if let majorityAt {
                    Rectangle()
                        .fill(Color.primary.opacity(0.84))
                        .frame(width: 2, height: height + 6)
                        .offset(x: unit * CGFloat(majorityAt) - 1)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.borderStrong, lineWidth: 1))
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }
}

/// Compact party tallies; letter badges make party state independent of color.
struct TallyChips: View {
    let comp: Composition
    var demLabel: String = "D"
    var repLabel: String = "R"

    var body: some View {
        HStack(spacing: 7) {
            chip(demLabel, comp.dem, Theme.dem, name: "Democratic")
            if comp.ind > 0 { chip("I", comp.ind, Theme.ind, name: "Independent") }
            chip(repLabel, comp.rep, Theme.rep, name: "Republican")
        }
    }

    private func chip(_ label: String, _ count: Int, _ color: Color, name: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 17, height: 17)
                .background(RoundedRectangle(cornerRadius: 4).fill(color))
            Text("\(count)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.trailing, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(count)")
    }
}

/// Native slider with a stable label column and explicit value readout.
struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var format: (Double) -> String
    var accent: Color = Theme.civic
    var width: CGFloat = 150

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .frame(width: width, alignment: .leading)
                .lineLimit(2)
            Slider(value: $value, in: range, step: step)
                .tint(accent)
                .accessibilityLabel(label)
                .accessibilityValue(format(value))
            Text(format(value))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 66, alignment: .trailing)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panelStrong))
        }
        .frame(minHeight: 28)
    }
}

struct Card<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var tint: Color = Theme.civic
    private let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        symbol: String? = nil,
        tint: Color = Theme.civic,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 25, height: 25)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(LinearGradient(colors: [tint.opacity(0.85), tint],
                                                 startPoint: .bottomLeading, endPoint: .topTrailing)))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            content
        }
        .padding(13)
        // Fill the row so sibling cards in a grid share one height and their
        // tops line up; a card that only takes its own height reads as crooked.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .refractiveGlass(cornerRadius: 12)
    }
}

struct ResultTile: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    var tint: Color = Theme.civic

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .font(.system(size: 10, weight: .semibold))
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint)
                .lineLimit(2)
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .refractiveInset(cornerRadius: 11)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.78))
                .frame(width: 3).padding(.vertical, 9)
        }
        .accessibilityElement(children: .combine)
    }
}

struct PartyChoiceGroup: View {
    let selection: Party?
    let onSelect: (Party?) -> Void

    var body: some View {
        HStack(spacing: 3) {
            choice("Model", symbol: "function", party: nil, tint: Theme.civic)
            choice("D", symbol: "d.circle.fill", party: .dem, tint: Theme.dem)
            choice("R", symbol: "r.circle.fill", party: .rep, tint: Theme.rep)
        }
        .padding(3)
        .refractiveInset(cornerRadius: 9)
    }

    private func choice(_ title: String, symbol: String, party: Party?, tint: Color) -> some View {
        let active = selection == party
        return Button { onSelect(party) } label: {
            HStack(spacing: 4) {
                Image(systemName: active ? "checkmark" : symbol)
                if title == "Model" { Text(title) }
            }
                .font(.system(size: 9, weight: .semibold))
                .frame(minWidth: title == "Model" ? 54 : 27, minHeight: 24)
                .padding(.horizontal, title == "Model" ? 4 : 0)
                .background(RoundedRectangle(cornerRadius: 7).fill(active ? tint : Color.clear))
                .foregroundStyle(active ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title == "Model" ? "Use model" : "Force \(title == "D" ? "Democratic" : "Republican")")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

struct EmptyState: View {
    let title: String
    let detail: String
    var symbol: String = "tray"

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.civic)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.civic.opacity(0.1)))
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .accessibilityElement(children: .combine)
    }
}

extension Party {
    var swatch: some View {
        Text(short)
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 15, height: 15)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.color(self)))
            .accessibilityLabel(name)
    }
}

func plusMinus(_ value: Double, _ digits: Int = 1) -> String {
    let formatted = String(format: "%.\(digits)f", abs(value))
    return value > 0 ? "D+\(formatted)" : value < 0 ? "R+\(formatted)" : "Even"
}
