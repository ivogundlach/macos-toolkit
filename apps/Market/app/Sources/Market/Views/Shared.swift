import SwiftUI
import AppKit

// CLT-only workaround: this Command Line Tools install ships SwiftUI/SwiftUICore
// but NOT the `SwiftUIMacros` plugin, so the macro-backed `@State` attribute
// cannot expand (`StateMacro` not found). Every OTHER property wrapper
// (@StateObject, @ObservedObject, @EnvironmentObject, @Environment, @AppStorage,
// @Binding, @Published) is still a plain property wrapper and works. `@State`
// is the sole casualty. ViewState is a drop-in replacement: it wraps SwiftUI's
// `State` struct (which still exists) and conforms to DynamicProperty, so
// SwiftUI updates it identically to real @State and `$value` yields a Binding.
@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    @usableFromInline var storage: State<Value>
    init(wrappedValue: Value) { storage = State(initialValue: wrappedValue) }
    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }
    var projectedValue: Binding<Value> { storage.projectedValue }
}

// MARK: - Market design system

/// App-local visual vocabulary. Market borrows Usage Queue's compact hierarchy,
/// adaptive surfaces and restrained shape scale without borrowing its palette or
/// layout. The cool blue accent belongs to navigation and primary actions;
/// bullish/bearish and operational colors remain semantic.
enum MarketUI {
    static let accent = adaptive(
        light: NSColor(srgbRed: 0.10, green: 0.31, blue: 0.68, alpha: 1),
        dark: NSColor(srgbRed: 0.43, green: 0.66, blue: 1.00, alpha: 1))
    static let accentSoft = accent.opacity(0.12)
    static let positive = adaptive(
        light: NSColor(srgbRed: 0.06, green: 0.42, blue: 0.22, alpha: 1),
        dark: NSColor(srgbRed: 0.36, green: 0.82, blue: 0.51, alpha: 1))
    static let negative = adaptive(
        light: NSColor(srgbRed: 0.70, green: 0.08, blue: 0.12, alpha: 1),
        dark: NSColor(srgbRed: 1.00, green: 0.42, blue: 0.44, alpha: 1))
    static let warning = adaptive(
        light: NSColor(srgbRed: 0.60, green: 0.31, blue: 0.00, alpha: 1),
        dark: NSColor(srgbRed: 1.00, green: 0.68, blue: 0.25, alpha: 1))
    static let indicatorBear = adaptive(
        light: NSColor(srgbRed: 0.42, green: 0.18, blue: 0.66, alpha: 1),
        dark: NSColor(srgbRed: 0.75, green: 0.52, blue: 0.96, alpha: 1))

    static let pageInset: CGFloat = 18
    static let regionSpacing: CGFloat = 14
    static let componentSpacing: CGFloat = 10
    static let microSpacing: CGFloat = 6

    // Liquid Glass. Card and region containers only — rows, controls, and the
    // hover/pressed fills below stay flat, because they sit inside those cards
    // and glass layered on glass reads as neither.
    static let cardGlass: Glass = .regular
    static let interactiveGlass: Glass = .regular.interactive()

    static let controlRadius: CGFloat = 8
    static let rowRadius: CGFloat = 9
    static let cardRadius: CGFloat = 12
    static let regionRadius: CGFloat = 15

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

struct MarketSectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

/// Standard page heading used by every primary destination and drilldown.
struct MarketPageHeader<Trailing: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let systemImage: String
    var tint: Color = MarketUI.accent
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                identity
                Spacer(minLength: 12)
                trailing()
            }
            VStack(alignment: .leading, spacing: 9) {
                identity
                HStack(spacing: 7) {
                    trailing()
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .refractiveGlass(cornerRadius: MarketUI.regionRadius)
    }

    private var identity: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: MarketUI.controlRadius, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.85), tint],
                                         startPoint: .bottomLeading, endPoint: .topTrailing))
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(eyebrow.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(tint)
                Text(title).font(.title2.weight(.semibold))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

extension MarketPageHeader where Trailing == EmptyView {
    init(eyebrow: String, title: String, subtitle: String, systemImage: String,
         tint: Color = MarketUI.accent) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle,
                  systemImage: systemImage, tint: tint, trailing: { EmptyView() })
    }
}

struct MarketStatusPill: View {
    let text: String
    let systemImage: String
    var color: Color = .secondary

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.12)))
            .overlay(Capsule().strokeBorder(color.opacity(0.22), lineWidth: 1))
            .accessibilityLabel(text)
    }
}

struct MarketPanel<Content: View>: View {
    let content: Content
    var inset: CGFloat = 14

    init(inset: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.inset = inset
        self.content = content()
    }

    var body: some View {
        content
            .padding(inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .refractiveGlass(cornerRadius: MarketUI.cardRadius)
    }
}

struct MarketTableHeader: View {
    let title: String
    var alignment: Alignment = .leading

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.55)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

struct MarketPrimaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
            .background(RoundedRectangle(cornerRadius: MarketUI.controlRadius, style: .continuous)
                .fill(MarketUI.accent.opacity(configuration.isPressed ? 0.76 : 1)))
            .contentShape(RoundedRectangle(cornerRadius: MarketUI.controlRadius, style: .continuous))
    }
}

struct MarketSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: MarketUI.controlRadius, style: .continuous)
                .fill(configuration.isPressed ? MarketUI.surfaceRaised : MarketUI.surface))
            .overlay(RoundedRectangle(cornerRadius: MarketUI.controlRadius, style: .continuous)
                .strokeBorder(MarketUI.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: MarketUI.controlRadius, style: .continuous))
    }
}

struct MarketRowBackground: ViewModifier {
    let selected: Bool
    @ViewState private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: MarketUI.rowRadius, style: .continuous)
                .fill(selected ? MarketUI.accentSoft
                      : (hovered ? MarketUI.surfaceRaised : Color.clear)))
            .overlay(RoundedRectangle(cornerRadius: MarketUI.rowRadius, style: .continuous)
                .strokeBorder(selected ? MarketUI.accent.opacity(0.28) : Color.clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: MarketUI.rowRadius, style: .continuous))
            .onHover { hovered = $0 }
    }
}

// Shared UI building blocks: status banner, color helpers, async-load container.

extension Color {
    static func direction(_ d: String) -> Color {
        d.lowercased().hasPrefix("bull") ? MarketUI.positive
            : (d.lowercased().hasPrefix("bear") ? MarketUI.negative : .secondary)
    }
    static func status(_ s: String) -> Color {
        switch s.lowercased() {
        case "active": return MarketUI.positive
        case "exited": return .secondary
        case "conflict": return MarketUI.warning
        default: return .secondary
        }
    }
}

/// Global command-state banner (queued/running/succeeded/failed + message).
struct CommandStatusBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 7) {
            switch model.lastCommand {
            case .idle:
                Image(systemName: model.backendReady ? "checkmark.circle" : "bolt.slash")
                    .foregroundStyle(model.backendReady ? MarketUI.positive : MarketUI.warning)
                Text(model.backendReady ? "Command bridge ready" : "Read-only · command bridge offline")
                    .font(.caption).foregroundStyle(.secondary)
            case .queued, .running:
                ProgressView().controlSize(.small)
                Text("\(model.lastCommandLabel)…")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            case .succeeded(let gen):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(MarketUI.positive)
                Text("\(model.lastCommandLabel) complete" + (gen.map { " · generation \($0)" } ?? ""))
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            case .failed(let msg):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(MarketUI.negative)
                Text("\(model.lastCommandLabel): \(msg)")
                    .font(.caption.weight(.medium)).foregroundStyle(MarketUI.negative).lineLimit(2)
            }
            Spacer()
            if let g = model.generation {
                Text("GEN \(g)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .frame(minHeight: 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .refractiveCanvas(forceDark: true)
        .overlay(alignment: .top) { Rectangle().fill(MarketUI.hairline).frame(height: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Command status")
    }
}

/// Wraps an async read: shows progress, error, then content. Reloads when
/// `revision` changes (e.g. after a write bumps dataRevision).
struct AsyncContent<T, Content: View>: View {
    let load: () async -> Result<T, Error>
    let revision: Int
    @ViewBuilder let content: (T) -> Content

    @ViewState private var phase: Phase = .loading
    enum Phase { case loading, loaded(T), failed(String) }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading market data")
                        .font(.callout.weight(.medium))
                    Text("Reading the latest committed generation")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(26)
                .refractiveGlass(cornerRadius: MarketUI.cardRadius)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Loading market data")
            case .loaded(let value):
                content(value)
            case .failed(let msg):
                EmptyStateView(
                    icon: "exclamationmark.triangle",
                    title: "Couldn't load",
                    message: msg,
                    color: MarketUI.negative)
            }
        }
        .task(id: revision) { await reload() }
    }

    private func reload() async {
        phase = .loading
        switch await load() {
        case .success(let v): phase = .loaded(v)
        case .failure(let e): phase = .failed("\(e)")
        }
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    var message: String = ""
    var color: Color = MarketUI.accent
    var body: some View {
        VStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: MarketUI.cardRadius)
                    .fill(color.opacity(0.12))
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(color)
            }
            .frame(width: 48, height: 48)
            Text(title).font(.headline)
            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
        .accessibilityElement(children: .combine)
    }
}

/// Migration / backend-not-ready guard shown in place of a screen's content.
struct BackendGate<Content: View>: View {
    @ObservedObject var model: AppModel
    var requiresWrite: Bool = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let err = model.schemaError {
            EmptyStateView(icon: "wrench.and.screwdriver",
                           title: "Backend needs migration",
                           message: err,
                           color: MarketUI.warning)
        } else if requiresWrite && !model.backendReady {
            EmptyStateView(icon: "bolt.horizontal.circle",
                           title: "Backend CLI not available yet",
                           message: "appctl.py was not found under \(model.paths.root)/pipeline. Reads still work; actions are disabled until the backend is installed.",
                           color: MarketUI.warning)
        } else {
            content()
        }
    }
}

/// A simple wrapping flow layout: lays children left-to-right and wraps to the
/// next line when the row would overflow the proposed width. Used so metric
/// tiles / chips reflow at narrow window widths instead of clipping.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                widest = max(widest, x - spacing)
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        widest = max(widest, x - spacing)
        let totalHeight = y + lineHeight
        let usedWidth = proposal.width ?? widest
        return CGSize(width: usedWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x > bounds.minX && (x - bounds.minX) + size.width > maxWidth {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                     proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Small labelled metric tile. Optional `help` shows a hover tooltip explaining
/// the metric.
struct MetricTile: View {
    let label: String
    let value: String
    var accent: Color = .primary
    var help: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let h = help, !h.isEmpty {
                    Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(accent)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        // Glass, not a flat fill with a uniform hairline. These tiles sit beside
        // cards that take their rim from the pointer, and a border that cannot
        // respond next to borders that do is what makes the window look like it
        // is lit by several unrelated lights.
        .refractiveInset(cornerRadius: MarketUI.controlRadius)
        // Single tooltip: the custom hover bubble only. (The native .help()
        // tooltip rendered as a clipped duplicate under this CLT SwiftUI build,
        // so it is intentionally NOT used here.)
        .contentShape(Rectangle())
        .hoverTip(help ?? "")
    }
}

/// Consistent dashboard card: an uppercase section label (with optional icon +
/// hover help and a trailing accessory) above its content, with uniform padding,
/// corner radius, a soft fill and a hairline border. Using one card everywhere
/// is what makes the surfaces read as a designed system rather than ad-hoc boxes.
struct DashCard<Content: View, Accessory: View>: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = MarketUI.accent
    var help: String? = nil
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 6) {
                if let img = systemImage {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(LinearGradient(colors: [tint.opacity(0.85), tint],
                                                 startPoint: .bottomLeading, endPoint: .topTrailing))
                        Image(systemName: img).font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 19, height: 19)
                }
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(tint)
                if let help, !help.isEmpty {
                    Image(systemName: "info.circle").font(.system(size: 9))
                        .foregroundStyle(.tertiary).hoverTip(help)
                }
                Spacer(minLength: 8)
                accessory()
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .refractiveGlass(cornerRadius: MarketUI.cardRadius)
    }
}

extension DashCard where Accessory == EmptyView {
    init(_ title: String, systemImage: String? = nil, tint: Color = MarketUI.accent,
         help: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, systemImage: systemImage, tint: tint, help: help,
                  accessory: { EmptyView() }, content: content)
    }
}

/// What a hovered element publishes for the app-level tooltip overlay: the text
/// plus a bounds anchor resolved later in the overlay's coordinate space.
struct TooltipData {
    let text: String
    let anchor: Anchor<CGRect>
}

/// Carries the currently-hovered element's tooltip up to the detail-pane overlay.
/// Only one element is hovered at a time, so reduce keeps the last non-nil.
struct TooltipKey: PreferenceKey {
    static var defaultValue: TooltipData? = nil
    static func reduce(value: inout TooltipData?, nextValue: () -> TooltipData?) {
        if let next = nextValue() { value = next }
    }
}

/// Immediate custom hover tooltip — does not depend on the native `.help()`
/// timing/quirks. The hovered element does NOT draw its own bubble: a local
/// overlay's `zIndex` only orders siblings within its own container, so a later
/// sibling section (e.g. "Top Picks") would paint over it. Instead the element
/// just PUBLISHES its text + bounds via a preference, and `tooltipOverlay()`
/// (attached once at the detail-pane level in RootView) draws a single bubble
/// above ALL content — never covered, never clipped.
struct HoverTip: ViewModifier {
    let text: String
    @ViewState private var show = false

    func body(content: Content) -> some View {
        content
            .onHover { show = $0 }
            .anchorPreference(key: TooltipKey.self, value: .bounds) { anchor in
                (show && !text.isEmpty) ? TooltipData(text: text, anchor: anchor) : nil
            }
    }
}

/// The single floating tooltip bubble. Fixed width; clamped horizontally to stay
/// inside the container's width near the right (or left) edge.
private struct TooltipBubble: View {
    let text: String
    let anchor: CGRect
    let container: CGSize
    private let tipWidth: CGFloat = 260
    private let margin: CGFloat = 8

    var body: some View {
        let maxX = max(margin, container.width - margin - tipWidth)
        let x = min(max(margin, anchor.minX), maxX)
        let y = anchor.maxY + 8
        Text(text)
            .font(.caption)
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .padding(8)
            .frame(width: tipWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: MarketUI.controlRadius).fill(Color(white: 0.12)))
            .overlay(RoundedRectangle(cornerRadius: MarketUI.controlRadius)
                .strokeBorder(.white.opacity(0.18)))
            .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
            .offset(x: x, y: y)
    }
}

extension View {
    func hoverTip(_ text: String) -> some View { modifier(HoverTip(text: text)) }

    func marketRow(selected: Bool = false) -> some View {
        modifier(MarketRowBackground(selected: selected))
    }

    /// Disable elastic scroll bounce on any axis whose content already fits, so a
    /// single-axis scroll view can't rubber-band on the cross axis. No-op below
    /// macOS 13.3 (the modifier's floor); the package deploys to 13.0.
    @ViewBuilder
    func noBounceWhenContentFits() -> some View {
        if #available(macOS 13.3, *) {
            self.scrollBounceBehavior(.basedOnSize, axes: [.horizontal, .vertical])
        } else {
            self
        }
    }

    /// Draw the single floating tooltip bubble above this view's content. Attach
    /// once to an ancestor of all `hoverTip` users (the detail pane) so the bubble
    /// paints over every section and is clamped inside this view's width.
    func tooltipOverlay() -> some View {
        overlayPreferenceValue(TooltipKey.self) { data in
            GeometryReader { proxy in
                if let data {
                    TooltipBubble(text: data.text,
                                  anchor: proxy[data.anchor],
                                  container: proxy.size)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Friendly source / origin formatting

let ytChannelNames: [String: String] = [
    "UC0BGhWsIbV7Dm-lsvhdlMbA": "ZipTrader",
    "UCnMn36GT_H0X-w5_ckLtlgQ": "Financial Education",
]

/// "x_tier1:wliang|youtube:UC0B..." -> "X (Tier 1) · @wliang, YouTube · ZipTrader"
func formatOrigins(_ originKey: String) -> String {
    originKey.split(separator: "|").map { part -> String in
        let comps = part.split(separator: ":", maxSplits: 1).map(String.init)
        let src = comps.first ?? String(part)
        let who = comps.count > 1 ? comps[1] : ""
        let label = sourceLabel(src)
        if src.hasPrefix("x_") { return who.isEmpty ? label : "\(label) · @\(who)" }
        if src == "youtube" { let nm = ytChannelNames[who] ?? "Channel"; return "\(label) · \(nm)" }
        return label
    }.joined(separator: ", ")
}

func authorLabel(source: String, author: String) -> String {
    if source == "youtube" { return ytChannelNames[author] ?? author }
    if source.hasPrefix("x_") { return author.hasPrefix("@") ? author : "@\(author)" }
    return author
}

/// Humanize a transition row's raw JSON detail into a clean sentence (no braces).
func humanTransition(code: String, detailJSON: String) -> String {
    let verb: String
    switch code {
    case "T1": verb = "Entered"
    case "T2": verb = "Threshold raised (bearish regime)"
    case "T3": verb = "Reinforced"
    case "T4": verb = "Decayed"
    case "T5": verb = "Exited (decayed)"
    case "T6": verb = "Exited (rank override)"
    case "T7": verb = "Conflict resolved"
    case "T8": verb = "Frozen (conflict)"
    case "T9": verb = "Entry frozen (stale coverage)"
    default: verb = code
    }
    guard let data = detailJSON.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return verb
    }
    var parts: [String] = []
    if let track = obj["track"] as? String { parts.append(titleCase(track)) }
    if let route = obj["route"] as? String { parts.append("route \(route)") }
    if let c = obj["clusters"] as? Double { parts.append("\(Int(c)) clusters") }
    if let conv = obj["conviction"] as? Double { parts.append("conviction \(Int(conv))") }
    if let reg = obj["regime"] as? Double { parts.append("regime \(String(format: "%.1f", reg))") }
    return parts.isEmpty ? verb : "\(verb) — " + parts.joined(separator: " · ")
}

func fmt(_ v: Double?, _ digits: Int = 1) -> String {
    guard let v else { return "—" }
    return String(format: "%.\(digits)f", v)
}

// MARK: - Display capitalization helpers
//
// These format DB-stored lowercase values for display ONLY. They never change
// the underlying database values (Swift is read-only). Use them everywhere a
// raw status / direction / source / track string is rendered.

/// Title-cases an arbitrary display string: capitalizes the first letter of each
/// whitespace- or underscore-separated word. Acronyms already in all-caps (e.g.
/// "VIX") are preserved. Empty / dash placeholders pass through unchanged.
func titleCase(_ s: String) -> String {
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed != "—", trimmed != "-" else { return s }
    return trimmed
        .replacingOccurrences(of: "_", with: " ")
        .split(separator: " ")
        .map { word -> String in
            let w = String(word)
            // Preserve existing all-caps acronyms (VIX, USD, …).
            if w.count <= 4 && w == w.uppercased() && w.rangeOfCharacter(from: .letters) != nil {
                return w
            }
            return w.prefix(1).uppercased() + w.dropFirst().lowercased()
        }
        .joined(separator: " ")
}

/// Display label for a recommendation status: active → Active, exited → Exited,
/// conflict → Conflict (anything else title-cased).
func displayStatus(_ s: String) -> String { titleCase(s) }

/// Display label for a signal direction: bullish → Bullish, bearish → Bearish.
func displayDirection(_ d: String) -> String { titleCase(d) }

/// Display label for a signal strength: strong → Strong, etc.
func displayStrength(_ s: String) -> String { titleCase(s) }

/// Display label for a track name: growth → Growth, value → Value, dividends → Dividends.
func displayTrack(_ t: String) -> String { titleCase(t) }

/// Display label for a derived_state source: model → Model, override → Override.
func displaySource(_ s: String?) -> String { titleCase(s ?? "model") }

/// Maps raw source keys (e.g. `x_tier1`, `youtube`, `regime`) to friendly,
/// human-readable labels for display. The single source-of-truth label map used
/// everywhere a source/origin key is rendered. Unknown keys are title-cased.
func sourceLabel(_ key: String) -> String {
    switch key.lowercased() {
    case "x_tier1": return "X (Tier 1)"
    case "x_tier2": return "X (Tier 2)"
    case "youtube": return "YouTube"
    case "tradingview": return "TradingView"
    case "discord": return "Discord"
    case "regime": return "Market Data"
    default: return titleCase(key)
    }
}

/// Converts a snake_case / lowercase config key into Title/Sentence case for
/// display. Recognizes a few domain-specific labels; falls back to capitalizing
/// each underscore-separated word.
func humanLabel(_ key: String) -> String {
    switch key.lowercased() {
    case "exit_below_conviction": return "Exit below conviction"
    case "decay_pct_per_trading_day": return "Decay % per trading day"
    case "min_clusters": return "Minimum clusters"
    case "window_trading_days": return "Window (trading days)"
    case "fear_greed": return "Fear / Greed"
    case "put_call": return "Put / Call"
    case "vix": return "VIX"
    case "vix_trend5d": return "VIX 5-day trend"
    case "growth": return "Growth"
    case "value": return "Value"
    case "dividends": return "Dividends"
    default:
        return key.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .enumerated()
            .map { i, w in i == 0 ? (w.prefix(1).uppercased() + w.dropFirst()) : String(w) }
            .joined(separator: " ")
    }
}

/// One-line muted explanation for a config field, shown inline under each control
/// in Settings (no hover tooltips in Settings per the design).
func settingExplanation(_ key: String) -> String {
    switch key.lowercased() {
    case "exit_below_conviction":
        return "A position exits this track when its conviction falls below this value."
    case "decay_pct_per_trading_day":
        return "How fast conviction bleeds off each trading day without fresh corroborating signals."
    case "min_clusters":
        return "Minimum number of distinct signal clusters required before a position can enter."
    case "window_trading_days":
        return "Look-back window, in trading days, used to gather signals for this track."
    default:
        return ""
    }
}
