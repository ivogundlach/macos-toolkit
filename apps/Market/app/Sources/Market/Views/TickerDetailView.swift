import SwiftUI
#if canImport(Charts)
import Charts
#endif

// View 4 — Ticker detail: events/signals (get-ticker), conviction history line
// chart (Swift Charts if available; else a hand-drawn Path), transitions/audit.

struct TickerDetail {
    let events: [EventRow]
    let signals: [Signal]
    let history: [ConvictionPoint]
    let transitions: [TransitionRow]
}

struct TickerDetailView: View {
    @EnvironmentObject var model: AppModel
    let ticker: String
    let onBack: () -> Void

    var body: some View {
        BackendGate(model: model) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button { onBack() } label: {
                        Label("Back to workspace", systemImage: "chevron.left")
                    }
                    .buttonStyle(MarketSecondaryButtonStyle())
                    .hoverTip("Return to the previous screen.")
                    .keyboardShortcut("[", modifiers: .command)
                    .accessibilityHint("Returns to the selected sidebar destination")
                    Spacer()
                    MarketStatusPill(text: ticker, systemImage: "chart.line.uptrend.xyaxis",
                                     color: MarketUI.accent)
                }
                .padding(.horizontal, MarketUI.pageInset).padding(.vertical, 10)
                .background(MarketUI.groupedSurface)
                .overlay(alignment: .bottom) { Rectangle().fill(MarketUI.hairline).frame(height: 1) }

                AsyncContent(load: { await load(ticker) }, revision: model.dataRevision) { detail in
                    content(detail)
                }
            }
        }
        .navigationTitle(ticker)
    }

    @ViewBuilder
    private func content(_ d: TickerDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MarketUI.regionSpacing) {
                MarketPageHeader(
                    eyebrow: "Ticker drilldown",
                    title: ticker,
                    subtitle: "Evidence timeline, conviction history and model-state audit.",
                    systemImage: "chart.line.uptrend.xyaxis"
                ) {
                    MarketStatusPill(text: "\(d.signals.count) signals",
                                     systemImage: "waveform", color: MarketUI.accent)
                }

                FlowLayout(spacing: 8, lineSpacing: 8) {
                    MetricTile(label: "Signals", value: "\(d.signals.count)")
                        .frame(width: 112)
                    MetricTile(label: "Evidence", value: "\(d.events.count)")
                        .frame(width: 112)
                    MetricTile(label: "Audit events", value: "\(d.transitions.count)")
                        .frame(width: 120)
                    MetricTile(label: "History points", value: "\(d.history.count)")
                        .frame(width: 126)
                }

                section("Conviction History") {
                    if d.history.isEmpty {
                        Text("No conviction history yet (appended by scheduled runs).")
                            .foregroundStyle(.secondary).font(.callout)
                    } else {
                        ConvictionChart(points: d.history)
                            .frame(height: 180)
                    }
                }

                section("Signals (\(d.signals.count))") {
                    if d.signals.isEmpty { emptyLine("No signals.") }
                    else {
                        ForEach(d.signals.prefix(40)) { s in
                            HStack(spacing: 8) {
                                Text(s.sessionDate).font(.caption).foregroundStyle(.tertiary).frame(width: 90, alignment: .leading)
                                Image(systemName: s.direction.lowercased().hasPrefix("bull")
                                      ? "arrow.up.right" : "arrow.down.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Color.direction(s.direction))
                                Text(displayDirection(s.direction)).foregroundStyle(Color.direction(s.direction)).frame(width: 70, alignment: .leading)
                                Text(displayStrength(s.strength)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                                Text(formatOrigins(s.originKey)).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .font(.callout)
                            .padding(.horizontal, 7).padding(.vertical, 5)
                            .marketRow()
                        }
                    }
                }

                section("Events (\(d.events.count))") {
                    if d.events.isEmpty { emptyLine("No events.") }
                    else {
                        ForEach(d.events.prefix(40)) { e in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(sourceLabel(e.source)).font(.caption.bold()).foregroundStyle(.secondary)
                                    Text(authorLabel(source: e.source, author: e.author)).font(.caption).foregroundStyle(.tertiary)
                                    Spacer()
                                    Text(e.ts).font(.caption).foregroundStyle(.tertiary)
                                }
                                Text(e.text).font(.callout).lineLimit(3)
                            }
                            .padding(9)
                            .background(RoundedRectangle(cornerRadius: MarketUI.rowRadius)
                                .fill(MarketUI.surfaceRaised))
                            .overlay(RoundedRectangle(cornerRadius: MarketUI.rowRadius)
                                .strokeBorder(MarketUI.hairline, lineWidth: 1))
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                section("Transitions / Audit (\(d.transitions.count))") {
                    if d.transitions.isEmpty { emptyLine("No transitions.") }
                    else {
                        ForEach(d.transitions) { t in
                            HStack(alignment: .top) {
                                Text(t.sessionDate).font(.caption).foregroundStyle(.tertiary).frame(width: 90, alignment: .leading)
                                Text(humanTransition(code: t.transition, detailJSON: t.detail))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 7).padding(.vertical, 5)
                            .marketRow()
                        }
                    }
                }
            }
            .padding(MarketUI.pageInset)
        }
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder _ body: () -> C) -> some View {
        MarketPanel {
            VStack(alignment: .leading, spacing: 10) {
                MarketSectionLabel(text: title)
                body()
            }
        }
    }

    private func emptyLine(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).font(.callout)
    }

    private func load(_ sym: String) async -> Result<TickerDetail, Error> {
        let repo = model.repo
        return await loadAsync {
            let r = try repo.ticker(sym)
            return TickerDetail(events: r.events, signals: r.signals,
                                history: r.history, transitions: r.transitions)
        }
    }
}

/// Conviction line chart. Uses Swift Charts when available under CLT; otherwise
/// a hand-drawn Path (CONTRACTS view spec explicitly allows the fallback).
struct ConvictionChart: View {
    let points: [ConvictionPoint]

    var body: some View {
        #if canImport(Charts)
        if #available(macOS 13.0, *) {
            Chart(points) { p in
                LineMark(x: .value("Date", p.sessionDate),
                         y: .value("Conviction", p.conviction))
                .interpolationMethod(.monotone)
                PointMark(x: .value("Date", p.sessionDate),
                          y: .value("Conviction", p.conviction))
            }
            .chartYScale(domain: 0...100)
        } else {
            PathChart(points: points)
        }
        #else
        PathChart(points: points)
        #endif
    }
}

/// Zero-dependency fallback line chart drawn with a Path.
struct PathChart: View {
    let points: [ConvictionPoint]
    var body: some View {
        GeometryReader { geo in
            let vals = points.map { $0.conviction }
            let maxV = 100.0
            let minV = 0.0
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                // gridlines
                ForEach([0.0, 25.0, 50.0, 75.0, 100.0], id: \.self) { g in
                    let y = h - CGFloat((g - minV) / (maxV - minV)) * h
                    Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y)) }
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                }
                Path { p in
                    guard !vals.isEmpty else { return }
                    for (i, v) in vals.enumerated() {
                        let x = vals.count == 1 ? w / 2 : CGFloat(i) / CGFloat(vals.count - 1) * w
                        let y = h - CGFloat((v - minV) / (maxV - minV)) * h
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                        else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
        }
    }
}
