import SwiftUI

// View — Indicators: the per-stock indicator-suite STATUS board (schema v5).
//
// One row per stock, showing its current Arch/Helix state on each timeframe as
// colored chips (green = bullish, purple = bearish, per the indicator suite), plus
// when it last changed. A deterministic readout of the TradingView alert emails —
// NOT the LLM conviction score (that lives under Recommendations).
//
// Same layout discipline as SignalsView: a fixed header + vertical-only scrolling
// rows (never a horizontal scroll); the status chips flow/wrap to fit the width.

struct IndicatorsView: View {
    @EnvironmentObject var model: AppModel

    private let wTicker: CGFloat = 74
    private let wChanged: CGFloat = 104

    var body: some View {
        BackendGate(model: model) {
            AsyncContent(load: load, revision: model.dataRevision) { rows in
                let groups = grouped(rows)
                VStack(alignment: .leading, spacing: 0) {
                    MarketPageHeader(
                        eyebrow: "Indicator suite",
                        title: "Indicators",
                        subtitle: "Current Arch and Helix states from TradingView alerts—not model conviction.",
                        systemImage: "waveform.path.ecg",
                        tint: Screen.indicators.tint
                    ) {
                        MarketStatusPill(text: "\(groups.count) stock\(groups.count == 1 ? "" : "s")",
                                         systemImage: "chart.bar.doc.horizontal",
                                         color: MarketUI.accent)
                    }
                    .padding(MarketUI.pageInset)

                    if groups.isEmpty {
                        EmptyStateView(
                            icon: "waveform.path.ecg",
                            title: "No Indicator Readings Yet",
                            message: "This board fills automatically as TradingView indicator-suite alerts arrive. The alert source is currently off; once it's live, each stock's Arch/Helix state and its changes appear here.")
                    } else {
                        headerRow
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 2) {
                                ForEach(groups, id: \.ticker) { g in
                                    stockRow(g)
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                        }
                        .background(MarketUI.groupedSurface)
                    }
                }
            }
        }
        .navigationTitle("Indicators")
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Ticker").frame(width: wTicker, alignment: .leading)
                .hoverTip("The stock. Click to open its detail (evidence, conviction history).")
            Text("Indicator status").frame(maxWidth: .infinity, alignment: .leading)
                .hoverTip("Each chip is one indicator on one timeframe: colored dot (green bullish / purple bearish), name, timeframe and phase. Wraps to fit — never scrolls sideways.")
            Text("Changed").frame(width: wChanged, alignment: .trailing)
                .hoverTip("When this stock most recently changed indicator state.")
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
    private func stockRow(_ g: StockGroup) -> some View {
        Button { model.openTicker(g.ticker) } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(g.ticker)
                    .font(.system(.callout, design: .monospaced).bold())
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .frame(width: wTicker, alignment: .leading)
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(g.rows) { r in chip(r) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(g.changed)
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: wChanged, alignment: .trailing)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 8)
            .marketRow()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibility(g)))
        .accessibilityHint("Opens ticker detail")
    }

    @ViewBuilder
    private func chip(_ r: IndicatorStatusRow) -> some View {
        HStack(spacing: 5) {
            Image(systemName: r.state.lowercased() == "bullish"
                  ? "arrow.up.right" : (r.state.lowercased() == "bearish" ? "arrow.down.right" : "minus"))
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(stateColor(r.state))
            Circle().fill(stateColor(r.state)).frame(width: 8, height: 8)
            Text(chipLabel(r))
                .font(.caption)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(stateColor(r.state).opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(stateColor(r.state).opacity(0.35), lineWidth: 1))
        .hoverTip(chipTip(r))
    }

    // MARK: derived data

    struct StockGroup { let ticker: String; let rows: [IndicatorStatusRow]; let changed: String }

    /// Group status rows by ticker, preserving the incoming order (most-recently
    /// changed first), and compute each stock's most recent change date.
    private func grouped(_ rows: [IndicatorStatusRow]) -> [StockGroup] {
        var order: [String] = []
        var byTicker: [String: [IndicatorStatusRow]] = [:]
        for r in rows {
            if byTicker[r.ticker] == nil { order.append(r.ticker) }
            byTicker[r.ticker, default: []].append(r)
        }
        return order.map { t in
            let rs = byTicker[t] ?? []
            let changed = rs.map(\.dateChanged).max() ?? ""
            return StockGroup(ticker: t, rows: rs, changed: changed)
        }
    }

    // MARK: presentation helpers

    /// Green = bullish, purple = bearish — matches the indicator suite's own colors
    /// (these chips literally represent the Arch/Helix green/purple states).
    private func stateColor(_ state: String) -> Color {
        switch state.lowercased() {
        case "bullish": return MarketUI.positive
        case "bearish": return MarketUI.indicatorBear
        default: return .secondary
        }
    }

    private func chipLabel(_ r: IndicatorStatusRow) -> String {
        var parts = [titleCase(r.indicator)]
        if !r.timeframe.isEmpty { parts.append(r.timeframe) }
        if let p = r.phase { parts.append(p) }
        return parts.joined(separator: " · ")
    }

    private func chipTip(_ r: IndicatorStatusRow) -> String {
        var s = "\(titleCase(r.indicator))"
        if !r.timeframe.isEmpty { s += " (\(r.timeframe))" }
        s += ": \(titleCase(r.state))"
        if let c = r.changedAt, !c.isEmpty { s += " since \(String(c.prefix(10)))" }
        if let prev = r.previousState, !prev.isEmpty { s += "; previously \(titleCase(prev))" }
        s += " · \(r.readCount) reading\(r.readCount == 1 ? "" : "s")"
        return s
    }

    private func accessibility(_ g: StockGroup) -> String {
        let states = g.rows.map { "\(titleCase($0.indicator)) \($0.timeframe) \(titleCase($0.state))" }
        return "\(g.ticker): " + states.joined(separator: ", ") + ", changed \(g.changed)"
    }

    private func load() async -> Result<[IndicatorStatusRow], Error> {
        let repo = model.repo
        return await loadAsync { try repo.indicatorStatus() }
    }
}
