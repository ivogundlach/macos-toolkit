import SwiftUI

/// One system resource, presented retrospectively.
///
/// Every tab except Processes is one of these: a bucketed day/week/month view read
/// from the SQLite store, not a live readout. Values change when the window changes
/// or a reload lands, never on the two-second sampling tick — a panel whose rows
/// appear and vanish while you read it cannot be read at all.
enum ResourceKind: String, CaseIterable, Identifiable {
    case energy, cpu, gpu, memory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .energy: return "Energy"
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "Memory"
        }
    }

    var symbol: String {
        switch self {
        case .energy: return "bolt.fill"
        case .cpu: return "cpu"
        case .gpu: return "cube.transparent"
        case .memory: return "memorychip"
        }
    }

    var tint: Color {
        switch self {
        case .energy: return VitalsTheme.energy
        case .cpu: return VitalsTheme.cpu
        case .gpu: return VitalsTheme.gpu
        case .memory: return VitalsTheme.memory
        }
    }

    /// The machine-level series this tab charts.
    var series: HistoryStore.Series {
        switch self {
        case .energy: return .systemWatts
        case .cpu: return .cpuLoad
        case .gpu: return .gpuUtilization
        case .memory: return .memoryUsed
        }
    }

    /// The per-process column its contributor table ranks by.
    var metric: HistoryStore.Metric {
        switch self {
        case .energy: return .energy
        case .cpu: return .cpu
        case .gpu: return .gpu
        case .memory: return .memory
        }
    }

    var chartTitle: String {
        switch self {
        case .energy: return "System Draw"
        case .cpu: return "CPU Load"
        case .gpu: return "GPU Utilisation"
        case .memory: return "Memory Used"
        }
    }

    var contributorTitle: String {
        switch self {
        case .energy: return "Top Drainers"
        case .cpu: return "Top CPU Consumers"
        case .gpu: return "Top GPU Consumers"
        case .memory: return "Largest Memory Users"
        }
    }

    /// Zero is a real idle reading for load, but for watts and bytes it means the
    /// sample carries no measurement, so it must not drag the average down.
    var ignoresZeroSamples: Bool { self == .energy || self == .memory }

    /// Percentages have a natural ceiling; watts and bytes autoscale.
    var chartMaximum: Double? { (self == .cpu || self == .gpu) ? 100 : nil }

    /// `cpu_load` is stored as a 0...1 fraction; every other series is recorded in
    /// the unit it is displayed in.
    func scaled(_ value: Double) -> Double { self == .cpu ? value * 100 : value }

    func formatSeries(_ value: Double) -> String {
        switch self {
        case .energy: return Fmt.watts(value, decimals: 1)
        case .cpu, .gpu: return Fmt.percent(value, decimals: 0)
        case .memory: return Fmt.bytes(value)
        }
    }

    /// Per-process values keep the same units as the process table.
    func formatContribution(_ value: Double) -> String {
        switch self {
        case .energy: return Fmt.power(value)
        case .cpu, .gpu: return Fmt.percent(value)
        case .memory: return Fmt.bytes(value)
        }
    }
}

/// How far back a retrospective tab looks, and how coarsely it buckets that span.
enum HistoryWindow: String, CaseIterable, Identifiable {
    case day, week, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        }
    }

    /// Hour-by-hour for a day, day-by-day for a week and a month.
    var bucketCount: Int {
        switch self {
        case .day: return 24
        case .week: return 7
        case .month: return 30
        }
    }

    var bucketSeconds: TimeInterval { self == .day ? 3600 : 86400 }

    var span: TimeInterval { Double(bucketCount) * bucketSeconds }

    var granularity: String { self == .day ? "hour by hour" : "day by day" }

    /// Buckets start on clock hours and midnights, so a bar means "Tuesday" rather
    /// than "some 24 hours ending now". Bucket maths uses fixed-length seconds, so
    /// buckets before a daylight-saving change can sit an hour off their label.
    private var alignment: Calendar.Component { self == .day ? .hour : .day }

    /// Start of the oldest bucket, given the newest bucket is the one holding `end`.
    func alignedStart(endingAt end: Date) -> Date {
        let anchor = Calendar.current.dateInterval(of: alignment, for: end)?.start ?? end
        return anchor.addingTimeInterval(-Double(bucketCount - 1) * bucketSeconds)
    }

    func label(for date: Date) -> String {
        switch self {
        case .day: return Self.hour.string(from: date)
        case .week: return Self.weekday.string(from: date)
        case .month: return Self.dayOfMonth.string(from: date)
        }
    }

    private static let hour = formatter("HH")
    private static let weekday = formatter("EEE")
    private static let dayOfMonth = formatter("d")

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        return f
    }
}

/// The last loaded window for each resource tab.
///
/// `ContentView` keys each tab `.id(kind)`, so leaving a tab destroys its view and
/// every `@State` in it. Without somewhere outside the view to keep the last
/// result, coming back means starting from nothing and staring at empty panes for
/// a second while the queries re-run — for data that has not changed. Keyed by tab
/// *and* window, because Day and Month are different questions.
@MainActor
final class HistoryCache {
    static let shared = HistoryCache()
    private var entries: [String: ResourceHistoryView.Loaded] = [:]

    private func key(_ kind: ResourceKind, _ window: HistoryWindow) -> String {
        "\(kind.rawValue)|\(window.rawValue)"
    }

    func value(_ kind: ResourceKind, _ window: HistoryWindow) -> ResourceHistoryView.Loaded? {
        entries[key(kind, window)]
    }

    func store(_ value: ResourceHistoryView.Loaded,
               for kind: ResourceKind, _ window: HistoryWindow) {
        entries[key(kind, window)] = value
    }
}

struct ResourceHistoryView: View {
    @ObservedObject var model: AppModel
    let kind: ResourceKind

    @State private var buckets: [HistoryStore.Bucket] = []
    @State private var batteryBuckets: [HistoryStore.Bucket] = []
    /// A whole-window aggregate of a second series, for one summary tile.
    @State private var companion: HistoryStore.Bucket?
    @State private var contributors: [HistoryStore.Contribution] = []
    @State private var batteryEdges: (first: Double, last: Double)?
    /// Fraction of the window with any recording behind it. Anything derived by
    /// multiplying an average by elapsed time is scaled by this, or it would invent
    /// energy that was never spent.
    @State private var coverage: Double = 0
    @State private var earliest: Date?
    @State private var windowStart = Date()
    @State private var windowEnd = Date()
    @State private var aiReport: AIInsightsReport?
    /// Decides which in-flight window load is still the current one. See `reload`.
    @State private var generation = 0
    /// False until this view has real data to show, from the cache or a query.
    @State private var hasLoaded = false

    private var window: HistoryWindow { model.historyWindow }
    private var span: TimeInterval { max(1, windowEnd.timeIntervalSince(windowStart)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                controls
                if !hasLoaded {
                    // Never the empty state while a load is in flight. "No samples
                    // recorded" is a claim about the history, and until the query
                    // comes back this view has no idea whether it is true — showing
                    // it anyway told you the week was empty every time you opened a
                    // tab for the first time.
                    skeleton
                } else if totalSamples == 0 {
                    emptyState
                } else {
                    // Fixed four tiles in a fixed position: nothing below them can
                    // ever push them around.
                    HStack(spacing: 8) {
                        ForEach(summaryTiles) { tile in
                            StatTile(title: tile.title, value: tile.value,
                                     caption: tile.caption, tint: tile.tint, symbol: tile.symbol)
                        }
                    }
                    charts
                    HStack(alignment: .top, spacing: 10) {
                        contributorTable
                        nowCard.frame(width: 268)
                    }
                    // Findings sit last, so the count changing cannot move anything
                    // the eye is already on.
                    if kind == .energy { findingsCard }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
        }
        .refractiveCanvas()
        .onAppear(perform: reload)
        .onChange(of: model.historyWindow) { _, _ in reload() }
        // Matches the 30s recording cadence: often enough to stay current, slow
        // enough that the page is never moving while it is being read.
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            reload()
        }
    }

    // MARK: - Header

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("", selection: $model.historyWindow) {
                ForEach(HistoryWindow.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 220)

            Text("\(window.granularity), ending \(Fmt.shortDateTime(windowEnd))")
                .font(VitalsTheme.labelSmall).foregroundStyle(.secondary)

            Spacer()

            if let earliest {
                Text("recording since \(Fmt.shortDateTime(earliest))")
                    .font(VitalsTheme.labelSmall).foregroundStyle(.tertiary)
            }
            Button { reload() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 10))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Reload this window from the history database")
        }
    }

    /// The page's own shape, empty, while the first window load is still running.
    ///
    /// Same panes in the same places at the same sizes as the loaded page, so the
    /// arrival of data fills them in rather than replacing one layout with another.
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { _ in
                    Color.clear.frame(height: 62)
                        .refractiveGlass(cornerRadius: VitalsTheme.cardRadius)
                }
            }
            Color.clear.frame(height: 128)
                .refractiveGlass(cornerRadius: VitalsTheme.cardRadius)
            HStack(alignment: .top, spacing: 10) {
                Color.clear.frame(height: 320)
                    .refractiveGlass(cornerRadius: VitalsTheme.cardRadius)
                Color.clear.frame(width: 268, height: 320)
                    .refractiveGlass(cornerRadius: VitalsTheme.cardRadius)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No \(kind.title.lowercased()) samples recorded in this window yet.")
                .font(VitalsTheme.label)
            Text("Vitals records a sample every 30 seconds while it runs. Enable background "
                 + "recording in Settings → Recording to keep the history complete while the "
                 + "app is closed — that is what makes an overnight or week-long view "
                 + "meaningful. A month view also needs the retention setting to reach that far back.")
                .font(VitalsTheme.labelSmall).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .refractiveGlass(cornerRadius: VitalsTheme.cardRadius)
        .overlay(RoundedRectangle(cornerRadius: VitalsTheme.cardRadius)
            .stroke(VitalsTheme.border, lineWidth: 1))
    }

    // MARK: - Charts

    private var charts: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionCard(title: kind.chartTitle,
                        accessory: peak.map { "peak \(kind.formatSeries($0))" }) {
                BarChart(data: chartData(buckets), tint: kind.tint, maximum: kind.chartMaximum)
            }
            if kind == .energy {
                SectionCard(title: "Battery Charge", accessory: "percent") {
                    BarChart(data: chartData(batteryBuckets, scaled: false),
                             tint: VitalsTheme.battery, maximum: 100)
                }
            }
        }
    }

    private func chartData(_ source: [HistoryStore.Bucket],
                           scaled: Bool = true) -> [BarChart.Datum] {
        var byIndex: [Int: Double] = [:]
        for bucket in source where bucket.index >= 0 && bucket.index < window.bucketCount {
            byIndex[bucket.index] = scaled ? kind.scaled(bucket.average) : bucket.average
        }
        return (0..<window.bucketCount).map { index in
            BarChart.Datum(id: index, value: byIndex[index],
                           label: window.label(for: date(ofBucket: index)))
        }
    }

    private func date(ofBucket index: Int) -> Date {
        windowStart.addingTimeInterval(Double(index) * window.bucketSeconds)
    }

    // MARK: - Window aggregates
    //
    // Derived from the buckets rather than re-queried: weighting each bucket average
    // by its sample count reproduces the true window average exactly.

    private var totalSamples: Int { buckets.reduce(0) { $0 + $1.samples } }

    private var average: Double? {
        guard totalSamples > 0 else { return nil }
        let sum = buckets.reduce(0.0) { $0 + $1.average * Double($1.samples) }
        return kind.scaled(sum / Double(totalSamples))
    }

    private var peak: Double? { buckets.map(\.peak).max().map(kind.scaled) }
    private var lowest: Double? { buckets.map(\.minimum).min().map(kind.scaled) }


    private struct TileSpec: Identifiable {
        let id: Int
        let title: String
        let value: String
        let caption: String
        let symbol: String
        let tint: Color
    }

    /// Always exactly four, so a tab that gains data never reflows.
    private var summaryTiles: [TileSpec] {
        let over = "over \(Fmt.duration(span))"
        switch kind {
        case .energy:
            let used = (average ?? 0) * span * coverage
            let change = batteryEdges.map { $0.last - $0.first }
            return [
                TileSpec(id: 0, title: "Average Draw",
                         value: average.map { Fmt.watts($0, decimals: 1) } ?? "—",
                         caption: over, symbol: "bolt.circle", tint: VitalsTheme.energy),
                TileSpec(id: 1, title: "Peak Draw",
                         value: peak.map { Fmt.watts($0, decimals: 1) } ?? "—",
                         caption: "highest sample", symbol: "arrow.up.right",
                         tint: VitalsTheme.critical),
                TileSpec(id: 2, title: "Energy Used", value: Fmt.energy(used),
                         caption: coverage < 0.9 ? "partial coverage" : "estimated",
                         symbol: "sum", tint: VitalsTheme.cpu),
                TileSpec(id: 3, title: "Battery Change",
                         value: change.map { String(format: "%+.0f%%", $0) } ?? "—",
                         caption: (change ?? 0) < 0 ? "net discharge" : "net charge",
                         symbol: "battery.75",
                         tint: (change ?? 0) < 0 ? VitalsTheme.warn : VitalsTheme.ok),
            ]
        case .cpu:
            return [
                TileSpec(id: 0, title: "Average Load",
                         value: average.map { Fmt.percent($0, decimals: 0) } ?? "—",
                         caption: over, symbol: "cpu", tint: VitalsTheme.cpu),
                TileSpec(id: 1, title: "Peak Load",
                         value: peak.map { Fmt.percent($0, decimals: 0) } ?? "—",
                         caption: "busiest sample", symbol: "arrow.up.right",
                         tint: VitalsTheme.critical),
                TileSpec(id: 2, title: "Attributed Power",
                         value: companion.map { Fmt.watts($0.average) } ?? "—",
                         caption: "average CPU draw", symbol: "bolt.fill",
                         tint: VitalsTheme.energy),
                samplesTile,
            ]
        case .gpu:
            return [
                TileSpec(id: 0, title: "Average Utilisation",
                         value: average.map { Fmt.percent($0, decimals: 0) } ?? "—",
                         caption: over, symbol: "cube.transparent", tint: VitalsTheme.gpu),
                TileSpec(id: 1, title: "Peak Utilisation",
                         value: peak.map { Fmt.percent($0, decimals: 0) } ?? "—",
                         caption: "busiest sample", symbol: "arrow.up.right",
                         tint: VitalsTheme.critical),
                TileSpec(id: 2, title: "GPU Power",
                         value: companion.map { Fmt.watts($0.average) } ?? "—",
                         caption: "average measured rail", symbol: "bolt.fill",
                         tint: VitalsTheme.energy),
                samplesTile,
            ]
        case .memory:
            return [
                TileSpec(id: 0, title: "Average Used",
                         value: average.map { Fmt.bytes($0) } ?? "—",
                         caption: over, symbol: "memorychip", tint: VitalsTheme.memory),
                TileSpec(id: 1, title: "Peak Used",
                         value: peak.map { Fmt.bytes($0) } ?? "—",
                         caption: "highest sample", symbol: "arrow.up.right",
                         tint: VitalsTheme.critical),
                TileSpec(id: 2, title: "Lowest Used",
                         value: lowest.map { Fmt.bytes($0) } ?? "—",
                         caption: "quietest sample", symbol: "arrow.down.right",
                         tint: VitalsTheme.ok),
                samplesTile,
            ]
        }
    }

    private var samplesTile: TileSpec {
        TileSpec(id: 3, title: "Samples", value: "\(totalSamples)",
                 caption: "\(Fmt.percent(coverage * 100, decimals: 0)) of window",
                 symbol: "chart.dots.scatter", tint: .secondary)
    }

    // MARK: - Contributors

    private var contributorTable: some View {
        SectionCard(title: kind.contributorTitle,
                    accessory: kind == .memory ? "ranked by average" : "ranked by total") {
            if contributors.isEmpty {
                Text("No per-process history recorded for this window.")
                    .font(VitalsTheme.labelSmall).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("Process").frame(width: 190, alignment: .leading)
                        if kind == .energy {
                            Text("Energy").frame(width: 76, alignment: .trailing)
                        }
                        Text("Average").frame(width: 76, alignment: .trailing)
                        Text("Peak").frame(width: 76, alignment: .trailing)
                        Text("Seen").frame(width: 52, alignment: .trailing)
                            .help("Share of the recorded samples in this window where this "
                                  + "process ranked high enough to be stored")
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.bottom, 3)

                    let top = contributors.map(rankValue).max() ?? 1
                    ForEach(contributors) { row in
                        HStack(spacing: 0) {
                            Text(row.name).font(VitalsTheme.mono)
                                .lineLimit(1).truncationMode(.middle)
                                .frame(width: 190, alignment: .leading)
                            if kind == .energy {
                                Text(Fmt.wattHours(row.energyJoules)).font(VitalsTheme.mono)
                                    .foregroundStyle(VitalsTheme.energy)
                                    .frame(width: 76, alignment: .trailing)
                            }
                            Text(kind.formatContribution(row.average)).font(VitalsTheme.mono)
                                .frame(width: 76, alignment: .trailing)
                            Text(kind.formatContribution(row.peak)).font(VitalsTheme.monoSmall)
                                .foregroundStyle(.secondary)
                                .frame(width: 76, alignment: .trailing)
                            Text(Fmt.percent(row.coverage * 100, decimals: 0))
                                .font(VitalsTheme.monoSmall).foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.06))
                                    Capsule().fill(kind.tint.opacity(0.75))
                                        .frame(width: geo.size.width
                                               * CGFloat(min(1, rankValue(row) / max(top, 0.0001))))
                                }
                            }
                            .frame(height: 6).padding(.leading, 8)
                        }
                        .frame(height: 17)
                    }
                }
            }
        }
    }

    /// The quantity the table is ordered by, mirrored in the bar length.
    private func rankValue(_ row: HistoryStore.Contribution) -> Double {
        kind == .memory ? row.average : row.average * Double(row.samples)
    }

    // MARK: - Current state
    //
    // The one deliberately live card per tab, for facts a time series cannot carry:
    // battery health, installed memory, the GPU itself. Its rows are a fixed set, so
    // refreshing it changes numbers and never layout.

    private var nowCard: some View {
        SectionCard(title: "Right Now", accessory: "live") {
            VStack(alignment: .leading, spacing: 6) {
                switch kind {
                case .energy: batteryDetail
                case .cpu: cpuDetail
                case .gpu: gpuDetail
                case .memory: memoryDetail
                }
            }
        }
    }

    private var battery: BatteryProbe.Stats { model.snapshot.battery }

    private var batteryDetail: some View {
        Group {
            MetricBar(label: "Charge", detail: "\(Int(battery.percent))%",
                      fraction: battery.percent / 100,
                      tint: battery.percent < 20 ? VitalsTheme.critical : VitalsTheme.battery)
            MetricBar(label: "Health", detail: "\(Int(battery.health * 100))%",
                      fraction: battery.health,
                      tint: battery.health < 0.8 ? VitalsTheme.warn : VitalsTheme.ok)
            keyValue("Cycles", "\(battery.cycleCount)")
            keyValue("Capacity", "\(battery.fullChargeCapacity)/\(battery.designCapacity) mAh")
            keyValue("Voltage", String(format: "%.2f V", battery.voltage))
            keyValue("Power source", battery.externalConnected ? "Adapter" : "Battery")
            keyValue("Thermal", model.snapshot.system.thermalPressure)
        }
    }

    private var cpuDetail: some View {
        let cores = model.snapshot.system.cores
        let performance = cores.filter(\.isPerformance).count
        return Group {
            keyValue("Load now", Fmt.percent(model.snapshot.system.cpuUsage * 100, decimals: 0))
            keyValue("Cores", "\(performance)P + \(cores.count - performance)E")
            keyValue("Load average",
                     model.snapshot.system.loadAverage.map { String(format: "%.2f", $0) }
                        .joined(separator: "  "))
            keyValue("Processes", "\(model.snapshot.totalProcesses)")
            keyValue("Unmeasurable", "\(model.snapshot.unreadableProcesses)")
            keyValue("Thermal", model.snapshot.system.thermalPressure)
            keyValue("Uptime", Fmt.duration(model.snapshot.system.uptime))
        }
    }

    private var gpuDetail: some View {
        let gpu = model.snapshot.gpu
        return Group {
            keyValue("Device", gpu.name)
            keyValue("Cores", "\(gpu.coreCount)")
            keyValue("Utilisation now", Fmt.percent(gpu.deviceUtilization, decimals: 0))
            keyValue("Renderer", Fmt.percent(gpu.rendererUtilization, decimals: 0))
            keyValue("Tiler", Fmt.percent(gpu.tilerUtilization, decimals: 0))
            keyValue("VRAM in use", Fmt.bytes(gpu.inUseMemory))
            keyValue("VRAM allocated", Fmt.bytes(gpu.allocatedMemory))
        }
    }

    private var memoryDetail: some View {
        let memory = model.snapshot.system.memory
        let total = max(Double(memory.total), 1)
        return Group {
            MetricBar(label: "App Memory", detail: Fmt.bytes(memory.appMemory),
                      fraction: Double(memory.appMemory) / total, tint: VitalsTheme.memory)
            MetricBar(label: "Wired", detail: Fmt.bytes(memory.wired),
                      fraction: Double(memory.wired) / total, tint: VitalsTheme.cpu)
            MetricBar(label: "Compressed", detail: Fmt.bytes(memory.compressed),
                      fraction: Double(memory.compressed) / total, tint: VitalsTheme.warn)
            MetricBar(label: "Cached Files", detail: Fmt.bytes(memory.cached),
                      fraction: Double(memory.cached) / total, tint: .gray)
            MetricBar(label: "Swap",
                      detail: "\(Fmt.bytes(memory.swapUsed)) of \(Fmt.bytes(memory.swapTotal))",
                      fraction: Double(memory.swapUsed) / Double(max(memory.swapTotal, 1)),
                      tint: VitalsTheme.critical)
            keyValue("Installed", Fmt.bytes(memory.total))
            keyValue("Pressure", Fmt.percent(memory.pressure * 100, decimals: 0))
        }
    }

    private func keyValue(_ key: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(key).font(VitalsTheme.labelSmall).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).font(VitalsTheme.monoSmall).lineLimit(1).truncationMode(.middle)
        }
    }

    // MARK: - Findings
    //
    // Read off the loaded window, so they describe a sustained pattern rather than
    // whichever process happened to spike during one two-second sample. Battery
    // health is not a finding: it is a fixed property of the machine and lives in
    // the card above, where it can be looked up instead of announced repeatedly.

    private struct Finding: Identifiable {
        let id: Int
        let text: String
        let symbol: String
        let tint: Color
    }

    private var findingsCard: some View {
        let items = findings
        let ai = aiReport?.section(for: window)
        return SectionCard(
            title: "Findings",
            accessory: ai.map { _ in "\(aiReport?.model ?? "Luna") • \(aiReport?.generatedLabel ?? "")" }
                ?? "measured facts"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if let ai {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("LUNA INTERPRETATION")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(VitalsTheme.energy)
                        Text(ai.summary).font(VitalsTheme.label)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(ai.findings) { finding in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .firstTextBaseline, spacing: 5) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 9))
                                        .foregroundStyle(VitalsTheme.energy)
                                    Text(finding.title).font(VitalsTheme.sectionTitle)
                                    Spacer(minLength: 0)
                                    Text("\(Int(ai.confidence * 100))% evidence")
                                        .font(VitalsTheme.labelSmall).foregroundStyle(.secondary)
                                }
                                Text(finding.interpretation).font(VitalsTheme.label)
                                    .fixedSize(horizontal: false, vertical: true)
                                ForEach(finding.evidence, id: \.self) { evidence in
                                    Text("Observed: \(evidence)").font(VitalsTheme.labelSmall)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                ForEach(finding.actions) { action in
                                    HStack(alignment: .top, spacing: 5) {
                                        Image(systemName: "arrow.right.circle.fill")
                                            .font(.system(size: 9)).foregroundStyle(VitalsTheme.ok)
                                            .padding(.top, 1)
                                        Text("\(action.title): \(action.detail)")
                                            .font(VitalsTheme.labelSmall)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                    Divider()
                } else {
                    Text("Luna analysis will appear after the next scheduled 04:00 run.")
                        .font(VitalsTheme.labelSmall).foregroundStyle(.secondary)
                }

                Text("MEASURED FACTS")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                if items.isEmpty {
                    Text("Nothing stood out over this window.")
                        .font(VitalsTheme.labelSmall).foregroundStyle(.secondary)
                } else {
                    ForEach(items) { finding in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: finding.symbol)
                                .font(.system(size: 10))
                                .foregroundStyle(finding.tint)
                                .frame(width: 14)
                            Text(finding.text).font(VitalsTheme.label)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private var findings: [Finding] {
        var out: [Finding] = []

        if let worst = contributors.first, worst.energyJoules > 0 {
            out.append(Finding(
                id: out.count,
                text: "\(worst.name) accounted for the most energy in this window — "
                    + "\(Fmt.energy(worst.energyJoules)) at an average of "
                    + "\(Fmt.power(worst.average)), present for "
                    + "\(Fmt.percent(worst.coverage * 100, decimals: 0)) of it.",
                symbol: "bolt.fill", tint: VitalsTheme.energy))
        }

        if let edges = batteryEdges {
            let change = edges.last - edges.first
            if change <= -1 {
                let rate = abs(change) / (span / 3600)
                out.append(Finding(
                    id: out.count,
                    text: String(format: "Battery fell %.0f%% over this window, about %.1f%% per hour.",
                                 abs(change), rate),
                    symbol: "battery.25", tint: VitalsTheme.warn))
            }
        }

        if model.snapshot.unreadableProcesses > 0 {
            out.append(Finding(
                id: out.count,
                text: "\(model.snapshot.unreadableProcesses) processes run as another user and "
                    + "cannot be measured, so their share is missing from these totals. "
                    + "Enable the privileged helper in Settings to attribute it.",
                symbol: "lock.fill", tint: .secondary))
        }

        if coverage < 0.75 {
            out.append(Finding(
                id: out.count,
                text: "Samples cover only \(Fmt.percent(coverage * 100, decimals: 0)) of this "
                    + "window, so averages describe the recorded periods, not the whole span. "
                    + "Background recording in Settings closes the gaps.",
                symbol: "chart.dots.scatter", tint: .secondary))
        }

        return out
    }

    // MARK: - Loading

    /// Everything one `reload` reads, so the queries can run together off the main
    /// thread and land on it as a single assignment.
    struct Loaded {
        var buckets: [HistoryStore.Bucket] = []
        var contributors: [HistoryStore.Contribution] = []
        var coverage: Double = 0
        var earliest: Date?
        var aiReport: AIInsightsReport?
        var batteryBuckets: [HistoryStore.Bucket] = []
        var batteryEdges: (first: Double, last: Double)?
        var companion: HistoryStore.Bucket?
    }

    /// Loads the window off the main thread.
    ///
    /// This used to run inline, and `ContentView` keys each resource tab with
    /// `.id(kind)`, so every tab switch built a fresh view, called this, and blocked
    /// the main thread until six SQLite queries had finished. `topContributors`
    /// alone measured 0.83 s against the real 142 MB history — it groups 1.36 M
    /// `proc_samples` rows by name, and no index covers that — so the whole app,
    /// including the tab bar that had just been clicked, was frozen for about a
    /// second on every switch. That is the tab lag; the queries were never the
    /// wrong queries, they were on the wrong thread.
    ///
    /// `generation` makes the result self-cancelling. Switching tabs faster than a
    /// load takes would otherwise let an older, slower query land on top of a newer
    /// one and show the previous tab's data under the current tab's heading.
    private func reload() {
        guard let store = model.historyStore else { return }
        let end = Date()
        let start = window.alignedStart(endingAt: end)
        windowStart = start
        windowEnd = end

        generation &+= 1
        let token = generation
        let kind = self.kind
        let currentWindow = window
        let bucketSeconds = window.bucketSeconds

        // Show the last answer for this tab immediately. It is a window ending a
        // few seconds ago rather than now, which for a day/week/month view is the
        // same picture; the fresh one replaces it in place when it lands.
        if !hasLoaded, let cached = HistoryCache.shared.value(kind, currentWindow) {
            apply(cached)
        }

        Task.detached(priority: .userInitiated) {
            var out = Loaded()
            out.buckets = store.bucketedSeries(kind.series, since: start, until: end,
                                               bucketSeconds: bucketSeconds,
                                               positiveOnly: kind.ignoresZeroSamples)
            out.contributors = store.topContributors(kind.metric, since: start,
                                                     until: end, limit: 15)
            out.coverage = store.coverage(since: start, until: end)
            out.earliest = store.earliestSample()
            out.aiReport = AIInsightsReport.load()

            // One bucket spanning the whole window is just a window-wide aggregate.
            let whole = max(1, end.timeIntervalSince(start))
            switch kind {
            case .energy:
                out.batteryBuckets = store.bucketedSeries(.battery, since: start, until: end,
                                                          bucketSeconds: bucketSeconds,
                                                          positiveOnly: true)
                out.batteryEdges = store.edgeValues(.battery, since: start, until: end)
            case .cpu:
                out.companion = store.bucketedSeries(.cpuWatts, since: start, until: end,
                                                     bucketSeconds: whole,
                                                     positiveOnly: true).first
            case .gpu:
                out.companion = store.bucketedSeries(.gpuWatts, since: start, until: end,
                                                     bucketSeconds: whole,
                                                     positiveOnly: true).first
            case .memory:
                break
            }

            let result = out
            await MainActor.run {
                HistoryCache.shared.store(result, for: kind, currentWindow)
                guard token == generation else { return }
                apply(result)
            }
        }
    }

    @MainActor
    private func apply(_ result: Loaded) {
        buckets = result.buckets
        contributors = result.contributors
        coverage = result.coverage
        earliest = result.earliest
        aiReport = result.aiReport
        batteryBuckets = result.batteryBuckets
        batteryEdges = result.batteryEdges
        companion = result.companion
        hasLoaded = true
    }
}
