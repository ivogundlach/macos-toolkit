import SwiftUI

// View 1 — Overview: a market-state dashboard. A regime "hero" card on top, then
// a responsive grid of glanceable cards (today's signals, market breadth, recent
// track changes, portfolio), then the full Top Picks list and the latest debrief.
// All cards share the `DashCard` design system for a consistent, designed look.

struct OverviewData {
    let regime: Regime?
    let topTracks: [TrackRow]
    let topReasoning: [String: String]   // ticker -> short reasoning for hover
    let runs: [RunRow]
    let debriefs: [(date: String, headline: String)]
    let latestDebrief: DebriefContent?   // full content; the app is the sole debrief surface
    let sessionDate: String?
    let signals: [Signal]                // latest-session signals
    let transitions: [TransitionRow]     // recent track transitions
    let scores: [TickerScore]            // per-ticker bullishness (breadth)
    let positions: [Position]
    let watchlists: [Watchlist]
}

struct OverviewView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        BackendGate(model: model) {
            AsyncContent(load: load, revision: model.dataRevision) { data in
                GeometryReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: MarketUI.regionSpacing) {
                            header(data)
                            regimeHero(data.regime)
                            cardsLayout(data, width: proxy.size.width - (MarketUI.pageInset * 2))
                            topPicksCard(data.topTracks, reasoning: data.topReasoning)
                            deliveryCard(runs: data.runs, debriefs: data.debriefs,
                                         full: data.latestDebrief)
                        }
                        .padding(MarketUI.pageInset)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .noBounceWhenContentFits()
                }
            }
        }
        .navigationTitle("Overview")
    }

    /// The four stat cards as a balanced two-column grid when there's room, else a
    /// single column. Built from plain HStack/VStack (no custom Layout) so the
    /// content can never report a width wider than the pane.
    @ViewBuilder
    private func cardsLayout(_ data: OverviewData, width: CGFloat) -> some View {
        if width >= 600 {
            HStack(alignment: .top, spacing: MarketUI.regionSpacing) {
                VStack(spacing: MarketUI.regionSpacing) {
                    todaysSignalsCard(data)
                    recentChangesCard(data.transitions)
                }.frame(maxWidth: .infinity)
                VStack(spacing: MarketUI.regionSpacing) {
                    breadthCard(data.scores)
                    portfolioCard(positions: data.positions, watchlists: data.watchlists)
                }.frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: MarketUI.regionSpacing) {
                todaysSignalsCard(data)
                breadthCard(data.scores)
                recentChangesCard(data.transitions)
                portfolioCard(positions: data.positions, watchlists: data.watchlists)
            }
        }
    }

    // MARK: - Header

    private func header(_ data: OverviewData) -> some View {
        MarketPageHeader(
            eyebrow: "Research desk",
            title: "Market Overview",
            subtitle: "Regime, evidence breadth, portfolio context and the latest committed debrief.",
            systemImage: "gauge.with.dots.needle.67percent",
            tint: Screen.overview.tint
        ) {
            HStack(spacing: 7) {
                if let d = data.sessionDate ?? data.regime?.sessionDate {
                    MarketStatusPill(text: d, systemImage: "calendar", color: MarketUI.accent)
                }
                if model.backendReady {
                    MarketStatusPill(text: "Live", systemImage: "checkmark.circle.fill",
                                     color: MarketUI.positive)
                }
            }
            if !model.backendReady {
                MarketStatusPill(text: "Read-only", systemImage: "bolt.slash.fill",
                                 color: MarketUI.warning)
            }
        }
    }

    // MARK: - Regime hero

    @ViewBuilder
    private func regimeHero(_ regime: Regime?) -> some View {
        if let r = regime {
            let score = r.score ?? 50
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 7) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MarketUI.accent)
                    MarketSectionLabel(text: "Market Conditions")
                    Spacer()
                    MarketStatusPill(text: displayDirection(r.label),
                                     systemImage: score >= 50 ? "arrow.up.right" : "arrow.down.right",
                                     color: regimeColor(score))
                }
                HStack(alignment: .center, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        RegimeGauge(score: score, label: r.label)
                            .contentShape(Rectangle())
                            .hoverTip("Market score \(fmt(score, 0))/100 → \(displayDirection(r.label)). 0 = max bearish, 100 = max bullish; a weighted blend of VIX, VIX 5d, Fear/Greed and Put/Call.")
                            .accessibilityLabel("Market regime \(displayDirection(r.label)), score \(Int(score)) out of 100")
                        Text(regimeRead(score))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: 172, alignment: .leading)
                    Rectangle().fill(MarketUI.hairline).frame(width: 1, height: 132)
                    metricTiles(r).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .refractiveGlass(cornerRadius: MarketUI.regionRadius)
        } else {
            MarketPanel {
                HStack(spacing: 10) {
                    Image(systemName: "gauge").foregroundStyle(MarketUI.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Market conditions unavailable").font(.callout.weight(.semibold))
                        Text("The regime feed has not committed a session yet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func regimeColor(_ score: Double) -> Color {
        if score >= 55 { return MarketUI.positive }
        if score < 45 { return MarketUI.negative }
        return MarketUI.warning
    }

    private func regimeRead(_ s: Double) -> String {
        switch s {
        case 65...: return "Risk-on — broadly bullish conditions."
        case 55..<65: return "Constructive — leaning bullish."
        case 45..<55: return "Mixed — no clear directional edge."
        case 35..<45: return "Cautious — leaning bearish."
        default: return "Risk-off — broadly bearish conditions."
        }
    }

    @ViewBuilder
    private func metricTiles(_ r: Regime) -> some View {
        let putCallHelp: String = {
            var s = "Equity put/call ratio. High ratios signal hedging/fear and lean bearish; low ratios lean bullish."
            if let note = r.oiNote, !note.isEmpty { s += "\n" + note }
            if let c = r.confidence, !c.isEmpty { s += "\nConfidence: \(titleCase(c))." }
            return s
        }()
        FlowLayout(spacing: 12, lineSpacing: 12) {
            MetricTile(label: "VIX", value: fmt(r.vix, 2),
                       help: "CBOE Volatility Index — market fear gauge (implied 30-day S&P 500 volatility). Lower = calmer = more bullish input to the score.")
                .frame(width: 120)
            MetricTile(label: "VIX 5d", value: fmt(r.vixTrend5d, 2),
                       help: "5-day change in VIX. Falling volatility (negative) is a more bullish input; rising volatility leans the score bearish.")
                .frame(width: 120)
            MetricTile(label: "Fear / Greed", value: fmt(r.fearGreed, 0),
                       help: "CNN Fear & Greed Index, 0 (extreme fear) to 100 (extreme greed). Higher = greedier = more bullish input to the score.")
                .frame(width: 130)
            MetricTile(label: "Put / Call", value: fmt(r.putCall, 3),
                       help: putCallHelp)
                .frame(width: 120)
        }
    }

    // MARK: - Today's signals

    private func todaysSignalsCard(_ data: OverviewData) -> some View {
        let bull = data.signals.filter { $0.direction.lowercased().hasPrefix("bull") }.count
        let bear = data.signals.count - bull
        return DashCard("Today's Signals", systemImage: "dot.radiowaves.left.and.right", tint: Screen.signals.tint,
                        help: "Evidence clusters from the latest session. Counts are signals (not tickers); top movers are the best-ranked tickers today.") {
            if data.signals.isEmpty {
                emptyRow("No signals in the latest session.")
            } else {
                HStack(spacing: 18) {
                    countStat(value: bull, label: "bullish", symbol: "arrowtriangle.up.fill", color: MarketUI.positive)
                    countStat(value: bear, label: "bearish", symbol: "arrowtriangle.down.fill", color: MarketUI.negative)
                }
                Divider().opacity(0.5)
                VStack(spacing: 6) {
                    ForEach(topMovers(data.signals, 5)) { s in
                        Button { model.openTicker(s.ticker) } label: {
                            HStack(spacing: 8) {
                                Circle().fill(Color.direction(s.direction)).frame(width: 7, height: 7)
                                Text(s.ticker).font(.system(.callout, design: .monospaced)).bold()
                                    .frame(width: 60, alignment: .leading)
                                Text(titleCase(s.strength)).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(s.voices) \(s.voices == 1 ? "voice" : "voices")")
                                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                            }
                            .padding(.horizontal, 7).padding(.vertical, 5)
                            .marketRow()
                        }.buttonStyle(.plain)
                            .accessibilityLabel("Open \(s.ticker), \(displayDirection(s.direction)), \(displayStrength(s.strength))")
                    }
                }
            }
        }
    }

    /// Best-ranked signal per ticker, lowest rank first, capped at n.
    private func topMovers(_ signals: [Signal], _ n: Int) -> [Signal] {
        var seen = Set<String>(); var out: [Signal] = []
        for s in signals.sorted(by: { $0.bestRank < $1.bestRank }) {
            if seen.insert(s.ticker).inserted { out.append(s); if out.count >= n { break } }
        }
        return out
    }

    // MARK: - Market breadth

    private func breadthCard(_ scores: [TickerScore]) -> some View {
        let bull = scores.filter { $0.lean == "Bullish" }.count
        let bear = scores.filter { $0.lean == "Bearish" }.count
        let neutral = scores.count - bull - bear
        let total = max(scores.count, 1)
        return DashCard("Market Breadth", systemImage: "chart.bar.xaxis", tint: MarketUI.accent,
                        help: "How many tracked tickers lean bullish vs bearish overall (from their latest-session signal balance). A wider read than the single regime gauge.") {
            if scores.isEmpty {
                emptyRow("No scored tickers yet.")
            } else {
                Text("\(bull) of \(scores.count) lean bullish")
                    .font(.title3.bold())
                BreadthBar(bull: bull, neutral: neutral, bear: bear)
                    .frame(height: 10)
                HStack(spacing: 16) {
                    legend(MarketUI.positive, "\(bull) bull")
                    legend(.secondary, "\(neutral) neutral")
                    legend(MarketUI.negative, "\(bear) bear")
                    Spacer()
                    Text("\(Int(Double(bull) / Double(total) * 100))%")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 9, height: 9)
            Text(t).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Recent changes

    private func recentChangesCard(_ transitions: [TransitionRow]) -> some View {
        DashCard("Recent Changes", systemImage: "arrow.triangle.swap", tint: MarketUI.indicatorBear,
                 help: "The latest track transitions — entries, conviction moves, exits and conflicts written by recent debrief runs.") {
            if transitions.isEmpty {
                emptyRow("No track changes recorded yet.")
            } else {
                VStack(spacing: 7) {
                    ForEach(transitions.prefix(6)) { t in
                        let info = transitionInfo(t.transition)
                        Button { model.openTicker(t.ticker) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: info.icon).font(.caption).foregroundStyle(info.color)
                                    .frame(width: 16)
                                Text(t.ticker).font(.system(.callout, design: .monospaced)).bold()
                                    .frame(width: 60, alignment: .leading)
                                Text(info.label).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if let track = detailField(t.detail, "track") {
                                    Text(titleCase(track)).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 7).padding(.vertical, 5)
                            .marketRow()
                        }.buttonStyle(.plain)
                            .accessibilityLabel("Open \(t.ticker), \(info.label)")
                    }
                }
            }
        }
    }

    /// Map a state-machine transition code (SPEC-state-machine.md) to a label,
    /// icon and color for display.
    private func transitionInfo(_ code: String) -> (label: String, icon: String, color: Color) {
        switch code.uppercased() {
        case "T1": return ("Entered", "arrow.right.circle.fill", MarketUI.positive)
        case "T2": return ("Watchlist only", "eye.circle.fill", .yellow)
        case "T3": return ("Conviction up", "arrow.up.circle.fill", MarketUI.positive)
        case "T4": return ("Decaying", "arrow.down.circle", MarketUI.warning)
        case "T5": return ("Exited · decayed", "xmark.circle.fill", .secondary)
        case "T6": return ("Exited · bearish", "xmark.circle.fill", MarketUI.negative)
        case "T7": return ("Conflict resolved", "arrow.triangle.branch", .yellow)
        case "T8": return ("Conflict", "exclamationmark.triangle.fill", MarketUI.warning)
        case "T9": return ("Frozen · stale", "snowflake", .cyan)
        case "T10": return ("Quarantined", "tray.full.fill", .secondary)
        default: return (titleCase(code), "circle.fill", .secondary)
        }
    }

    /// Pull a string/number field out of a transition's JSON `detail` blob.
    private func detailField(_ json: String, _ key: String) -> String? {
        guard let d = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let v = obj[key] else { return nil }
        if let n = v as? Double { return n == n.rounded() ? String(Int(n)) : "\(n)" }
        return "\(v)"
    }

    // MARK: - Portfolio

    private func portfolioCard(positions: [Position], watchlists: [Watchlist]) -> some View {
        let watched = Set(watchlists.flatMap { $0.tickers }).count
        let holding = positions.map { $0.symbol }
        return DashCard("Portfolio", systemImage: "briefcase", tint: Screen.positions.tint,
                        help: "Your holdings and watchlists at a glance. Manage them on the Watchlists & Positions screen.") {
            HStack(spacing: 24) {
                bigStat(positions.count, "positions")
                bigStat(watchlists.count, "watchlists")
            }
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 6) {
                labeledList("Holding", holding.isEmpty ? "—" : holding.joined(separator: ", "))
                labeledList("Watching", watchlists.isEmpty
                            ? "—"
                            : "\(watched) tickers · " + watchlists.map { $0.name }.joined(separator: ", "))
            }
        }
    }

    private func labeledList(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).font(.caption2.weight(.semibold)).tracking(0.5)
                .foregroundStyle(.tertiary)
            Text(value).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    // MARK: - Top Picks

    private func topPicksCard(_ tracks: [TrackRow], reasoning: [String: String]) -> some View {
        DashCard("Top Picks", systemImage: "star", tint: Color(red: 0.83, green: 0.62, blue: 0.10),
                 help: "The highest-conviction standing buy recommendations across all tracks. Open Recommendations for the full list. Click a row to drill into the ticker.") {
            if tracks.isEmpty {
                emptyRow("No active recommendations.")
            } else {
                VStack(spacing: 3) {
                    HStack(spacing: 10) {
                        MarketTableHeader(title: "Ticker").frame(width: 70)
                        MarketTableHeader(title: "Track").frame(width: 90)
                        MarketTableHeader(title: "Status").frame(width: 80)
                        Spacer()
                        MarketTableHeader(title: "Conviction", alignment: .trailing).frame(width: 140)
                    }
                    .padding(.horizontal, 8).padding(.bottom, 2)
                    Divider().opacity(0.6)
                    ForEach(tracks.prefix(8)) { t in
                        Button { model.openTicker(t.ticker) } label: {
                            HStack {
                                Text(t.ticker).font(.system(.body, design: .monospaced)).bold()
                                    .frame(width: 70, alignment: .leading)
                                Text(displayTrack(t.track)).foregroundStyle(.secondary)
                                    .frame(width: 90, alignment: .leading)
                                Text(displayStatus(t.status)).foregroundStyle(Color.status(t.status))
                                    .frame(width: 80, alignment: .leading)
                                Spacer()
                                ConvictionBar(value: t.conviction)
                                Text(fmt(t.conviction, 0)).monospacedDigit()
                                    .frame(width: 40, alignment: .trailing)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .font(.callout)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .marketRow()
                        }
                        .buttonStyle(.plain)
                        .hoverTip(pickReasoning(t, reasoning))
                        .accessibilityLabel("Open \(t.ticker), \(displayTrack(t.track)), conviction \(Int(t.conviction))")
                    }
                }
            }
        }
    }

    private func pickReasoning(_ t: TrackRow, _ reasoning: [String: String]) -> String {
        let head = "\(t.ticker) — \(displayTrack(t.track)) track, \(displayStatus(t.status)), conviction \(fmt(t.conviction, 0))/100."
        if let why = reasoning[t.ticker], !why.isEmpty {
            return head + "\nWhy: " + why + " Click to open the ticker."
        }
        return head + "\nConviction rises on corroborated signals and decays without fresh support. Click to open the ticker."
    }

    // MARK: - Latest debrief

    private func deliveryCard(runs: [RunRow], debriefs: [(date: String, headline: String)],
                              full: DebriefContent?) -> some View {
        DashCard("Latest Debrief", systemImage: "doc.text", tint: Screen.tracks.tint) {
            if let last = runs.first {
                HStack {
                    Text("Last run").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(titleCase(last.kind)) · \(last.startedAt)").monospacedDigit()
                }.font(.callout)
            } else {
                Text("No runs recorded yet.").foregroundStyle(.secondary).font(.callout)
            }
            if let d = full {
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(d.date).font(.caption).foregroundStyle(.tertiary)
                        if !d.sessionLabel.isEmpty {
                            Text(d.sessionLabel).font(.caption).foregroundStyle(.tertiary)
                        }
                        if d.degraded {
                            MarketStatusPill(text: "Degraded",
                                             systemImage: "exclamationmark.triangle.fill",
                                             color: MarketUI.warning)
                        }
                    }
                    if !d.headline.isEmpty {
                        Text(d.headline).font(.callout.weight(.semibold))
                    }
                    if !d.summary.isEmpty {
                        Text(d.summary).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    ForEach(d.byRank) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Rank \(s.rank) sources").font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(s.summary).font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    if !d.watchNotes.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Watch notes").font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(d.watchNotes).font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            let older = debriefs.filter { $0.date != full?.date }
            if !older.isEmpty {
                Divider().opacity(0.5)
                ForEach(older, id: \.date) { d in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.date).font(.caption).foregroundStyle(.tertiary)
                        Text(d.headline).font(.callout)
                    }
                }
            }
        }
    }

    // MARK: - Small shared bits

    private func countStat(value: Int, label: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.caption).foregroundStyle(color)
            Text("\(value)").font(.title2.bold()).monospacedDigit().foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func bigStat(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(value)").font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Load

    private func load() async -> Result<OverviewData, Error> {
        let repo = model.repo
        return await loadAsync {
            let top = try repo.tracks().filter { $0.status.lowercased() == "active" }
            var reasoning: [String: String] = [:]
            for t in top.prefix(8) {
                if let why = try repo.reasoning(for: t.ticker) { reasoning[t.ticker] = why }
            }
            let (sessionDate, signals) = try repo.latestSessionSignals()
            return OverviewData(
                regime: try repo.latestRegime(),
                topTracks: top,
                topReasoning: reasoning,
                runs: try repo.recentRuns(limit: 5),
                debriefs: try repo.debriefHeadlines(limit: 3),
                latestDebrief: try repo.latestDebrief(),
                sessionDate: sessionDate,
                signals: signals,
                transitions: try repo.recentTransitions(limit: 8),
                scores: try repo.tickerBullishness(),
                positions: try repo.positions(),
                watchlists: try repo.watchlists())
        }
    }
}

/// Horizontal stacked breadth bar: bullish (green) · neutral (grey) · bearish (red).
struct BreadthBar: View {
    let bull: Int
    let neutral: Int
    let bear: Int

    var body: some View {
        GeometryReader { geo in
            let total = max(bull + neutral + bear, 1)
            let w = geo.size.width
            HStack(spacing: 1) {
                seg(MarketUI.positive, bull, total, w)
                seg(Color.secondary.opacity(0.5), neutral, total, w)
                seg(MarketUI.negative, bear, total, w)
            }
            .clipShape(Capsule())
        }
    }

    private func seg(_ c: Color, _ n: Int, _ total: Int, _ w: CGFloat) -> some View {
        c.frame(width: max(n == 0 ? 0 : 2, w * CGFloat(n) / CGFloat(total)))
    }
}

/// Full circular regime ring (0 bearish .. 100 bullish). Circle() is always
/// inscribed in its frame and `.padding(lineWidth/2)` keeps the stroke inside,
/// so the gauge stays within its fixed square frame at any window size.
struct RegimeGauge: View {
    let score: Double
    let label: String
    private let lineWidth: CGFloat = 12
    private var s: Double { min(max(score, 0), 100) }

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(s / 100))
                .stroke(gaugeColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text(fmt(s, 0))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(gaugeColor)
                Text(displayDirection(label)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .padding(lineWidth / 2 + 2)
        .frame(width: 138, height: 138)
    }

    private var gaugeColor: Color {
        switch score {
        case ..<35: return MarketUI.negative
        case 35..<45: return MarketUI.warning
        case 45..<55: return .yellow
        case 55..<65: return .mint
        default: return MarketUI.positive
        }
    }
}

struct ConvictionBar: View {
    let value: Double  // 0..100
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(barColor)
                    .frame(width: max(2, geo.size.width * CGFloat(min(max(value, 0), 100) / 100)))
            }
        }
        .frame(width: 90, height: 6)
    }
    private var barColor: Color {
        value >= 50 ? MarketUI.positive : (value >= 25 ? .yellow : MarketUI.warning)
    }
}
