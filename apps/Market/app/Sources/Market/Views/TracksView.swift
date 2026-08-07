import SwiftUI

// View 2 — Recommendations: Growth/Value/Dividends recommendations from
// derived_state (fallback tracks). Row actions call appctl override
// (pin/unpin/force_exit[Remove]/resolve_conflict).
//
// Layout: a fixed header + vertical-only scrolling rows (NOT a SwiftUI Table)
// so columns flex to fit the available width and never overflow horizontally.
// Clicking a column header sorts by that column (toggling asc/desc). Clicking a
// ticker (here or in the all-tickers search/browse) opens its drilldown.

enum TrackSort: String { case ticker, status, conviction, source, entered }

struct TracksData {
    let tracks: [TrackRow]
    let allTickers: [String]
    let bullishness: [TickerScore]
}

struct TracksView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var selectedTrack: String = "growth"
    @ViewState private var sortKey: TrackSort = .conviction
    @ViewState private var sortAscending: Bool = false
    @ViewState private var search: String = ""
    private let trackOrder = ["growth", "value", "dividends"]

    var body: some View {
        BackendGate(model: model) {
            AsyncContent(load: load, revision: model.dataRevision) { data in
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        header(data)
                        searchBar(data)
                    }
                    .padding(MarketUI.pageInset)
                    .padding(.bottom, 2)
                    if search.trimmingCharacters(in: .whitespaces).isEmpty {
                        recommendationsTable(data.tracks)
                    } else {
                        searchResults(data)
                    }
                }
            }
        }
        .navigationTitle("Recommendations")
    }

    private func header(_ data: TracksData) -> some View {
        let active = data.tracks.filter { $0.status.lowercased() == "active" }.count
        return MarketPageHeader(
            eyebrow: "Standing ideas",
            title: "Recommendations",
            subtitle: "Slow-moving positions ranked by corroborated evidence and conviction decay.",
            systemImage: "chart.line.uptrend.xyaxis",
            tint: Screen.tracks.tint
        ) {
            MarketStatusPill(text: "\(active) active", systemImage: "star.fill",
                             color: MarketUI.positive)
        }
    }

    // MARK: Search box (searches ALL tickers in the DB, not just recommended)

    @ViewBuilder
    private func searchBar(_ data: TracksData) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search all tickers…", text: $search)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search all market tickers")
                .hoverTip("Search every ticker in the database — not just recommended ones. Click a result to open its detail.")
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Clear ticker search")
                    .accessibilityLabel("Clear ticker search")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: MarketUI.controlRadius).fill(MarketUI.surface))
        .overlay(RoundedRectangle(cornerRadius: MarketUI.controlRadius)
            .strokeBorder(MarketUI.hairline, lineWidth: 1))
    }

    // MARK: Recommendations table (per-track)

    @ViewBuilder
    private func recommendationsTable(_ tracks: [TrackRow]) -> some View {
        let rows = sorted(tracks.filter { $0.track.lowercased() == selectedTrack })
        HStack(spacing: 10) {
            Picker("Recommendation track", selection: $selectedTrack) {
                ForEach(trackOrder, id: \.self) { Text(displayTrack($0)).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .hoverTip("Switch between the Growth, Value and Dividends recommendation tracks.")
            Spacer()
            MarketStatusPill(text: "\(rows.count) \(displayTrack(selectedTrack))",
                             systemImage: "line.3.horizontal.decrease",
                             color: MarketUI.accent)
        }
        .padding(.horizontal, MarketUI.pageInset)
        .padding(.bottom, 10)

        if rows.isEmpty {
            EmptyStateView(icon: "tray", title: "No \(displayTrack(selectedTrack)) recommendations",
                           message: "This track has no standing positions in the latest generation.")
        } else {
            tableHeader
            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(rows) { t in
                        recommendationRow(t)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .background(MarketUI.groupedSurface)
        }
    }

    // Column widths: fixed-width columns + a flexible Actions area. The Ticker
    // column is first and always visible. Conviction (bar) and Actions flex via
    // maxWidth; everything wraps/truncates-free within the window — no sideways
    // scroll at any width.
    private let wStatus: CGFloat = 76
    private let wSource: CGFloat = 72
    private let wEntered: CGFloat = 86
    private let wActions: CGFloat = 42

    private var tableHeader: some View {
        HStack(spacing: 8) {
            sortHeader("Ticker", .ticker,
                       "The instrument symbol. Click to open its detail (events, signals, conviction history). Click this header to sort.")
                .frame(minWidth: 70, maxWidth: .infinity, alignment: .leading)
            sortHeader("Status", .status,
                       "Active = currently recommended; Conflict = contradictory signals, frozen.")
                .frame(width: wStatus, alignment: .leading)
            sortHeader("Conviction", .conviction,
                       "0–100 confidence score; rises with corroborating signals, decays without fresh support.")
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            sortHeader("Source", .source,
                       "Model = entered by the scoring engine; Override = you pinned/forced it.")
                .frame(width: wSource, alignment: .leading)
            sortHeader("Entered", .entered,
                       "Date this ticker entered the track.")
                .frame(width: wEntered, alignment: .leading)
            Image(systemName: "ellipsis.circle").frame(width: wActions, alignment: .center)
                .contentShape(Rectangle())
                .hoverTip("Manage: Pin, Unpin, Remove, or Resolve a conflict.")
        }
        .font(.system(size: 10, weight: .semibold))
        .textCase(.uppercase)
        .tracking(0.45)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(MarketUI.groupedSurface)
        .overlay(alignment: .bottom) { Rectangle().fill(MarketUI.hairline).frame(height: 1) }
    }

    /// A clickable column header that sorts by `key` (toggling asc/desc), shows
    /// the active sort direction with a chevron, and explains the column on hover.
    @ViewBuilder
    private func sortHeader(_ title: String, _ key: TrackSort, _ explanation: String) -> some View {
        Button {
            if sortKey == key { sortAscending.toggle() }
            else { sortKey = key; sortAscending = (key == .ticker || key == .status || key == .source) }
        } label: {
            HStack(spacing: 3) {
                Text(title.uppercased()).font(.system(size: 10, weight: .semibold))
                if sortKey == key {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down").font(.caption2)
                }
            }
            // Make the whole header cell (text + padding) a hit-testable shape so
            // the hover tooltip registers across the cell, not just the glyphs.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTip(explanation)
    }

    @ViewBuilder
    private func recommendationRow(_ t: TrackRow) -> some View {
        HStack(spacing: 8) {
            Button { model.openTicker(t.ticker) } label: {
                Text(t.ticker).font(.system(.body, design: .monospaced)).bold()
                    .frame(minWidth: 70, maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverTip("\(t.ticker) — open detail (events, signals, conviction history, audit).")

            MarketStatusPill(text: displayStatus(t.status),
                             systemImage: t.status.lowercased() == "conflict"
                                ? "exclamationmark.triangle.fill" : "circle.fill",
                             color: Color.status(t.status))
                .frame(width: wStatus, alignment: .leading)
                .hoverTip("Status: Active (currently recommended), Exited (decayed/closed) or Conflict (model and override disagree).")
            HStack(spacing: 6) {
                ConvictionBar(value: t.conviction)
                Text(fmt(t.conviction, 0)).monospacedDigit()
            }
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            .hoverTip("Conviction \(fmt(t.conviction, 0))/100. Enters on corroborated signals; decays each trading day without fresh support.")
            Text(displaySource(t.source)).foregroundStyle(.secondary)
                .frame(width: wSource, alignment: .leading)
                .hoverTip((t.source ?? "model") == "override"
                      ? "Manually set by an override (takes precedence over the model)."
                      : "Derived by the model from incoming signals.")
            Text(t.enteredAt ?? "—").foregroundStyle(.secondary)
                .frame(width: wEntered, alignment: .leading).lineLimit(1)
                .hoverTip("When this recommendation first entered the track.")
            trackActions(t).frame(width: wActions, alignment: .center)
        }
        .font(.callout)
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .marketRow()
    }

    @ViewBuilder
    private func trackActions(_ t: TrackRow) -> some View {
        Menu {
            Button { override("pin", t) } label: { Label("Pin", systemImage: "pin.fill") }
            Button { override("unpin", t) } label: { Label("Unpin", systemImage: "pin.slash") }
            Divider()
            Button(role: .destructive) { override("force_exit", t) } label: {
                Label("Remove", systemImage: "xmark.circle")
            }
            if t.status.lowercased() == "conflict" {
                Button { override("resolve_conflict", t) } label: {
                    Label("Resolve conflict", systemImage: "arrow.triangle.branch")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!model.backendReady)
        .help(model.backendReady ? "Manage \(t.ticker)" : "Command bridge offline")
        .accessibilityLabel("Manage recommendation \(t.ticker)")
    }

    // MARK: Search / browse all tickers (empty search = all by bullishness)

    @ViewBuilder
    private func searchResults(_ data: TracksData) -> some View {
        let q = search.trimmingCharacters(in: .whitespaces).uppercased()
        // Rank known scored tickers first (by bullishness), then any DB tickers
        // matching the query that have no score. Results are clickable.
        let scored = data.bullishness.filter { $0.ticker.uppercased().contains(q) }
        let scoredSet = Set(scored.map { $0.ticker.uppercased() })
        let extra = data.allTickers.filter { $0.contains(q) && !scoredSet.contains($0) }
        if scored.isEmpty && extra.isEmpty {
            EmptyStateView(icon: "magnifyingglass", title: "No tickers match \(q)")
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(scored) { ts in tickerScoreRow(ts) }
                    ForEach(extra, id: \.self) { sym in plainTickerRow(sym) }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .background(MarketUI.groupedSurface)
        }
    }

    private func tickerScoreRow(_ ts: TickerScore) -> some View {
        Button { model.openTicker(ts.ticker) } label: {
            HStack(spacing: 10) {
                Text(ts.ticker).font(.system(.body, design: .monospaced)).bold()
                    .frame(width: 80, alignment: .leading)
                Circle().fill(Color.direction(ts.lean)).frame(width: 8, height: 8)
                Text(displayDirection(ts.lean)).foregroundStyle(Color.direction(ts.lean))
                    .frame(width: 80, alignment: .leading)
                if ts.bullish > 0 || ts.bearish > 0 {
                    Text("\(ts.bullish)▲ \(ts.bearish)▼").font(.caption).foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .leading)
                } else {
                    Text("—").font(.caption).foregroundStyle(.tertiary)
                        .frame(width: 70, alignment: .leading)
                }
                Spacer()
                if let c = ts.conviction {
                    Text("Conv \(fmt(c, 0))").font(.caption).foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .marketRow()
        }
        .buttonStyle(.plain)
        .hoverTip("\(ts.ticker): \(displayDirection(ts.lean)) (\(ts.bullish) bullish / \(ts.bearish) bearish signals this session). Click to open detail.")
        .accessibilityLabel("Open \(ts.ticker), \(displayDirection(ts.lean))")
    }

    private func plainTickerRow(_ sym: String) -> some View {
        Button { model.openTicker(sym) } label: {
            HStack(spacing: 10) {
                Text(sym).font(.system(.body, design: .monospaced)).bold()
                    .frame(width: 80, alignment: .leading)
                Text("No recent signals").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .marketRow()
        }
        .buttonStyle(.plain)
        .hoverTip("\(sym): no signals this session. Click to open detail.")
        .accessibilityLabel("Open \(sym), no recent signals")
    }

    // MARK: sorting

    private func sorted(_ rows: [TrackRow]) -> [TrackRow] {
        let asc = sortAscending
        func cmp<T: Comparable>(_ a: T, _ b: T) -> Bool { asc ? a < b : a > b }
        switch sortKey {
        case .ticker:     return rows.sorted { cmp($0.ticker, $1.ticker) }
        case .status:     return rows.sorted { cmp($0.status.lowercased(), $1.status.lowercased()) }
        case .conviction: return rows.sorted { cmp($0.conviction, $1.conviction) }
        case .source:     return rows.sorted { cmp(($0.source ?? "model"), ($1.source ?? "model")) }
        case .entered:    return rows.sorted { cmp(($0.enteredAt ?? ""), ($1.enteredAt ?? "")) }
        }
    }

    private func override(_ op: String, _ t: TrackRow) {
        Task {
            await model.runCommand(
                "override \(op) \(t.ticker)", "override",
                args: ["op": .string(op),
                       "ticker": .string(t.ticker),
                       "track": .string(t.track)],
                recomputes: true)
        }
    }

    private func load() async -> Result<TracksData, Error> {
        let repo = model.repo
        return await loadAsync {
            TracksData(tracks: try repo.tracks(),
                       allTickers: try repo.allTickers(),
                       bullishness: try repo.tickerBullishness())
        }
    }
}
