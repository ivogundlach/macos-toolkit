import SwiftUI

// View 3 — Today's signals: dense table from signals latest session_date.
// ticker, direction (color), strength, track, voices (distinct origin keys), sources.
//
// Implemented as a fixed header + a vertical-only scrolling list of rows (NOT a
// SwiftUI Table) so the Sources cell can WRAP to multiple lines and grow the row
// height. The app never scrolls horizontally; the Sources column flexes and
// always shows every source.

struct SignalsView: View {
    @EnvironmentObject var model: AppModel

    // Column widths for the fixed-width leading columns; Sources takes the rest.
    private let wTicker: CGFloat = 70
    private let wDirection: CGFloat = 90
    private let wStrength: CGFloat = 80
    private let wTrack: CGFloat = 90
    private let wRank: CGFloat = 46

    var body: some View {
        BackendGate(model: model) {
            AsyncContent(load: load, revision: model.dataRevision) { result in
                VStack(alignment: .leading, spacing: 0) {
                    MarketPageHeader(
                        eyebrow: "Latest session",
                        title: "Today's Signals",
                        subtitle: "Aggregated evidence clusters, ranked by source strength and provenance.",
                        systemImage: "dot.radiowaves.left.and.right",
                        tint: Screen.signals.tint
                    ) {
                        HStack(spacing: 7) {
                            if let d = result.0 {
                                MarketStatusPill(text: d, systemImage: "calendar", color: MarketUI.accent)
                            }
                            MarketStatusPill(text: "\(result.1.count) signals",
                                             systemImage: "waveform", color: .secondary)
                        }
                    }
                    .padding(MarketUI.pageInset)

                    if result.1.isEmpty {
                        EmptyStateView(icon: "dot.radiowaves.left.and.right",
                                       title: "No Signals for the Latest Session")
                    } else {
                        headerRow
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 2) {
                                ForEach(result.1) { s in
                                    signalRow(s)
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                        }
                        .background(MarketUI.groupedSurface)
                    }
                }
            }
        }
        .navigationTitle("Today's signals")
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Ticker").frame(width: wTicker, alignment: .leading)
                .hoverTip("The instrument the signal is for. Click a ticker to open its detail.")
            Text("Direction").frame(width: wDirection, alignment: .leading)
                .hoverTip("Bullish or bearish lean of the aggregated signal.")
            Text("Strength").frame(width: wStrength, alignment: .leading)
                .hoverTip("Signal strength: Strong, Moderate or Weak.")
            Text("Track").frame(width: wTrack, alignment: .leading)
                .hoverTip("Proposed recommendation track (Growth / Value / Dividends), if any.")
            Text("Rank").frame(width: wRank, alignment: .trailing)
                .hoverTip("Best source rank backing this signal (1 = highest-tier source).")
            Text("Sources").frame(maxWidth: .infinity, alignment: .leading)
                .hoverTip("Sources that contributed, by friendly name, with the source count inline. Wraps to fit — never scrolls sideways.")
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .tracking(0.45)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(MarketUI.groupedSurface)
        .overlay(alignment: .bottom) { Rectangle().fill(MarketUI.hairline).frame(height: 1) }
    }

    @ViewBuilder
    private func signalRow(_ s: Signal) -> some View {
        let labels = friendlySources(s.sources)
        // Combined Sources cell text: the source list with the source count inline.
        let sourcesText = labels.joined(separator: ", ") + " · \(s.voices) Source\(s.voices == 1 ? "" : "s")"
        Button { model.openTicker(s.ticker) } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(s.ticker)
                    .font(.system(.callout, design: .monospaced).bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: wTicker, alignment: .leading)
                signalPill(displayDirection(s.direction),
                           icon: s.direction.lowercased().hasPrefix("bull") ? "arrow.up.right" : "arrow.down.right",
                           color: Color.direction(s.direction))
                .frame(width: wDirection, alignment: .leading)
                Text(displayStrength(s.strength)).frame(width: wStrength, alignment: .leading)
                Text(s.trackProposal == "none" ? "—" : displayTrack(s.trackProposal))
                    .foregroundStyle(.secondary)
                    .frame(width: wTrack, alignment: .leading)
                Text("\(s.bestRank)").monospacedDigit().frame(width: wRank, alignment: .trailing)
                // Combined Sources cell: source list + voice count inline. Wraps,
                // grows the row height, never clips or scrolls sideways.
                Text(sourcesText)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout)
            .padding(.horizontal, 7)
            .padding(.vertical, 7)
            .marketRow()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(s.ticker), \(displayDirection(s.direction)), \(displayStrength(s.strength)), \(s.trackProposal == "none" ? "no track" : displayTrack(s.trackProposal)), rank \(s.bestRank), \(sourcesText)"))
        .accessibilityHint("Opens ticker detail")
        .hoverTip("\(s.ticker): \(displayDirection(s.direction)), \(displayStrength(s.strength)), \(sourcesText).")
    }

    private func signalPill(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
            .overlay(Capsule().strokeBorder(color.opacity(0.22), lineWidth: 1))
            .lineLimit(1)
    }

    /// Maps the raw source keys to friendly labels and de-duplicates while
    /// preserving order.
    private func friendlySources(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for k in keys {
            let label = sourceLabel(k)
            if seen.insert(label).inserted { out.append(label) }
        }
        return out
    }

    private func load() async -> Result<(String?, [Signal]), Error> {
        let repo = model.repo
        return await loadAsync {
            let r = try repo.latestSessionSignals()
            return (r.sessionDate, r.signals)
        }
    }
}
