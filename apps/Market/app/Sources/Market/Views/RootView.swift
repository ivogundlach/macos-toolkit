import SwiftUI

// Left sidebar / NavigationSplitView shell. Dense, clean, native look (adopts
// the system light/dark appearance automatically).

enum Screen: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case tracks = "Recommendations"
    case signals = "Today's Signals"
    case indicators = "Indicators"
    case positions = "Watchlists & Positions"
    case settings = "Settings"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .tracks: return "chart.line.uptrend.xyaxis"
        case .signals: return "dot.radiowaves.left.and.right"
        case .indicators: return "waveform.path.ecg"
        case .positions: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        }
    }

    /// Sidebar tile hue per destination (System Settings style). Bullish green
    /// and bearish red stay reserved for market semantics inside the screens.
    var tint: Color {
        switch self {
        case .overview: return Color(red: 0.20, green: 0.44, blue: 0.86)
        case .tracks: return Color(red: 0.16, green: 0.56, blue: 0.44)
        case .signals: return Color(red: 0.87, green: 0.54, blue: 0.14)
        case .indicators: return Color(red: 0.55, green: 0.36, blue: 0.78)
        case .positions: return Color(red: 0.12, green: 0.56, blue: 0.64)
        case .settings: return Color(red: 0.48, green: 0.52, blue: 0.58)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var selection: Screen? = .overview
    // Keep the sidebar visible alongside the detail pane in balanced style so the
    // detail content is never underlapped/clipped by an overlaid sidebar.
    @ViewState private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                sidebarBrand
                List(selection: $selection) {
                    Section("Research") {
                        navRow(.overview)
                        navRow(.tracks)
                        navRow(.signals)
                        navRow(.indicators)
                    }
                    Section("Portfolio") {
                        navRow(.positions)
                    }
                    Section("System") {
                        navRow(.settings)
                    }
                }
                .listStyle(.sidebar)
                sidebarFooter
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 240)
            .refractiveCanvas(forceDark: true)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    // Ticker Detail is a drilldown (not a sidebar screen): when a
                    // ticker is selected it replaces the current screen with a
                    // "Back" affordance; otherwise show the selected sidebar screen.
                    if let ticker = model.drilldownTicker {
                        TickerDetailView(ticker: ticker, onBack: { model.closeTicker() })
                    } else {
                        detail(for: selection ?? .overview)
                    }
                }
                // Fill the detail pane and pin content to the leading edge so the
                // first column / headings render flush-left inside the pane —
                // never underlapped by the sidebar overlay.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                CommandStatusBar(model: model)
            }
            // A flexible minimum (not a fixed width wider than the pane) so the
            // detail content lays out from its own leading edge and is never
            // pushed under the sidebar at narrow widths.
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .refractiveCanvas(forceDark: true)
            // Single floating tooltip bubble, drawn above ALL detail content so
            // later sections (e.g. "Top Picks") never paint over it.
            .tooltipOverlay()
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        model.refreshBackendStatus()
                        model.dataRevision += 1
                    } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Refresh backend status and reload the current view")
                    .accessibilityLabel("Refresh market data")
                }
            }
        }
        // Keep both columns side-by-side (balanced) so the detail pane sits
        // beside — not beneath — the sidebar, and the detail's left edge is always
        // fully visible regardless of sidebar state.
        .navigationSplitViewStyle(.balanced)
        // Allow the whole window to shrink to a reasonable small size; content
        // reflows/wraps at narrow widths and nothing is clipped.
        .frame(minWidth: 720, minHeight: 480)
    }

    @ViewBuilder
    private func navRow(_ screen: Screen) -> some View {
        NavigationLink(value: screen) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .fill(screen.tint)
                    Image(systemName: screen.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 21, height: 21)
                Text(screen.rawValue)
                    .font(.callout.weight(selection == screen ? .semibold : .regular))
            }
            .padding(.vertical, 2)
        }
        // Plain value, not `screen as Screen?`: on macOS 26 the explicit optional
        // cast double-wraps and the tag stops matching an `Optional` selection.
        .tag(screen)
        .accessibilityLabel(screen.rawValue)
    }

    private var sidebarBrand: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: MarketUI.controlRadius, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.07, green: 0.20, blue: 0.48),
                                                  Color(red: 0.20, green: 0.44, blue: 0.86)],
                                         startPoint: .bottomLeading, endPoint: .topTrailing))
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("MARKET").font(.system(size: 13, weight: .bold)).tracking(0.8)
                Text("Research terminal").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: model.backendReady ? "checkmark.circle.fill" : "bolt.slash.fill")
                    .foregroundStyle(model.backendReady ? MarketUI.positive : MarketUI.warning)
                Text(model.backendReady ? "Pipeline connected" : "Read-only mode")
                    .font(.caption.weight(.medium))
            }
            Text(model.root.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MarketUI.groupedSurface)
        .overlay(alignment: .top) { Rectangle().fill(MarketUI.hairline).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func detail(for screen: Screen) -> some View {
        switch screen {
        case .overview: OverviewView()
        case .tracks: TracksView()
        case .signals: SignalsView()
        case .indicators: IndicatorsView()
        case .positions: PositionsView()
        case .settings: SettingsView()
        }
    }
}
