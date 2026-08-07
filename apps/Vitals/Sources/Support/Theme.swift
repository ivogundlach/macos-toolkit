import SwiftUI

/// Extends the fleet's token pattern (Theme / DashboardTheme / MarketUI) rather than
/// introducing a new design system. Adds density tokens, because the whole point of
/// this app is fitting more on screen than Activity Monitor does.
enum VitalsTheme {
    // Surfaces
    static let page = Color(nsColor: .windowBackgroundColor)
    static let sidebar = Color(nsColor: .underPageBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let inset = Color(nsColor: .textBackgroundColor)
    static let border = Color.primary.opacity(0.085)
    static let borderStrong = Color.primary.opacity(0.16)
    /// Stand-in for the glass slab on the one surface that cannot afford it.
    ///
    /// `glassEffect` is a backdrop blur, so it re-renders whenever anything inside
    /// it changes — and this pane's content changes on every sampling tick, whether
    /// or not anyone is scrolling. That makes it a *standing* cost, not a per-frame
    /// one: interleaved A/B on a 1800×1000 pane measured 74–76% GPU sitting idle
    /// with the material versus 8–15% without, while the extra cost of scrolling
    /// was about six points either way. Scrolling stuttered because the material
    /// had already spent the budget, not because scrolling was expensive. Read the
    /// two numbers from the same run: system GPU utilisation drifts far enough
    /// between runs to invent a difference this size on its own.
    ///
    /// No arrangement avoided it — behind the table, over an opaque interior, and
    /// stripped of its shadows all measured the same. This fill sits at the
    /// material's apparent lightness so the pane still reads as a slab.
    static let paneFill = Color.primary.opacity(0.05)
    /// Process rows band in runs of five instead of alternating. A zebra on a 20pt
    /// row has to choose between invisible and noisy — at 2.8% it was invisible, and
    /// anything strong enough to see stripes 400 rows. A band every five gives the
    /// eye a single edge to track across ten columns, and a way to count rows, for
    /// one eighth of the marks.
    static let rowBand = Color.primary.opacity(0.055)
    static let rowBandRun = 5

    static let controlRadius: CGFloat = 9
    static let cardRadius: CGFloat = 12
    static let groupRadius: CGFloat = 14

    /// One spacing scale. Everything that pads, insets, or gaps picks from here.
    /// The process view used to mix 4, 6, 7, 8, 9, 10 and 12 in a single screen,
    /// with the pane's margin smaller than the padding inside it — which is what
    /// makes a dense table read as a cramped one rather than a deliberate one.
    /// Density comes from the row height, not from starving the edges.
    static let padXS: CGFloat = 4
    static let padS: CGFloat = 8
    static let padM: CGFloat = 12
    static let padL: CGFloat = 16

    /// How far the process table's own content sits in from the pane's lit rim.
    /// At `padM` the first process name cleared the rim by about eight points,
    /// which reads as content pressed against the edge of its container rather
    /// than placed inside it.
    static let tableInset: CGFloat = 20


    // Liquid Glass. Bounded to containers — tiles, section cards, the tab bar,
    // and the process table's own pane.
    // Process rows deliberately stay flat: this app exists to fit hundreds of
    // 18pt rows on screen, and per-row glass would cost both the frame budget
    // and the density. The pane is one glass surface however many rows it holds;
    // the material's cost scales with the number of blended surfaces, not area.
    static let cardGlass: Glass = .regular
    /// Selected chrome stays a *solid* accent fill rather than tinted glass:
    /// glass tint goes pale in light appearance and white-on-it fails contrast.

    // Density: one hue per metric so a column reads at a glance across every tab.
    static let cpu = Color(red: 0.24, green: 0.47, blue: 0.85)
    static let gpu = Color(red: 0.58, green: 0.35, blue: 0.78)
    static let memory = Color(red: 0.13, green: 0.55, blue: 0.50)
    static let energy = Color(red: 0.85, green: 0.55, blue: 0.12)
    static let disk = Color(red: 0.42, green: 0.40, blue: 0.85)
    static let network = Color(red: 0.10, green: 0.58, blue: 0.72)
    static let battery = Color(red: 0.22, green: 0.60, blue: 0.35)
    static let wakeups = Color(red: 0.78, green: 0.35, blue: 0.55)

    // Severity, reserved for health signals only.
    static let ok = Color(red: 0.22, green: 0.60, blue: 0.35)
    static let warn = Color(red: 0.80, green: 0.58, blue: 0.10)
    static let critical = Color(red: 0.79, green: 0.25, blue: 0.23)

    /// Rows are 18pt so roughly twice as many processes fit as in Activity Monitor.
    static let rowHeight: CGFloat = 18
    /// Taller than a row on purpose. The kicker is small type, and small type set
    /// tight against a rule above it and rows below it is the single clearest
    /// "cheap" tell in a table; the header is the one line that can afford air.
    /// All of that air lives in this one number rather than being split between a
    /// height and a separate top inset — split, the two halves stop matching and
    /// the kicker ends up visibly closer to one edge than the other.
    static let headerHeight: CGFloat = 34
    static let mono = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let monoSmall = Font.system(size: 10, weight: .regular, design: .monospaced)
    static let label = Font.system(size: 11)
    static let labelSmall = Font.system(size: 10)
    static let sectionTitle = Font.system(size: 11, weight: .semibold)

    /// Green through red ramp for a 0...1 load, used by bars and core grids.
    static func loadColor(_ fraction: Double) -> Color {
        let f = min(1, max(0, fraction))
        if f < 0.5 { return ok.opacity(0.55 + f * 0.9) }
        if f < 0.8 { return warn }
        return critical
    }

    /// Colour a process row's energy figure by how much it matters.
    static func energyColor(_ milliwatts: Double) -> Color {
        switch milliwatts {
        case ..<50: return .secondary
        case ..<250: return energy.opacity(0.85)
        case ..<1000: return warn
        default: return critical
        }
    }
}
