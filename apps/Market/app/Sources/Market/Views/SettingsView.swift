import SwiftUI

// Settings — the single merged configuration & status screen. Collapses the
// former Settings + Sources & weights + Health screens into one section:
//   • Backend ROOT
//   • Weights & thresholds (rank weights, regime weights, per-track thresholds)
//   • Sources (enable/disable + handles/channels)
//   • Denylist & aliases
//   • Pipeline health (schema/generation, adapters, run lock, run ledger, logs)
//   • Config version & history
//
// Every control has a one-line muted INLINE explanation under it (no hover
// tooltips here — that is the Settings-section design). All writes still go
// through appctl (Swift never writes config/db directly, per CONTRACTS.md).

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    // ROOT / denylist / alias editors.
    @ViewState private var rootEdit: String = ""
    @ViewState private var newDenyTicker: String = ""
    @ViewState private var newAlias: String = ""
    @ViewState private var newCanonical: String = ""

    // Weights & thresholds edit buffers (committed only via Apply).
    @ViewState private var rankWeights: [Int: Double] = [:]
    @ViewState private var regimeWeights: [String: Double] = [:]
    @ViewState private var trackThresholds: [String: [String: Double]] = [:]
    @ViewState private var sourceEnabled: [String: Bool] = [:]
    @ViewState private var hydrated = false
    @ViewState private var dirty = false

    // Health buffers.
    @ViewState private var health: AppCtlResponse?
    @ViewState private var healthError: String?
    @ViewState private var lockMeta: String?
    @ViewState private var logTail: String = ""

    private let thresholdFields = ["exit_below_conviction", "decay_pct_per_trading_day",
                                   "min_clusters", "window_trading_days"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MarketUI.regionSpacing) {
                header
                rootCard
                if model.schemaError == nil {
                    if let cfg = model.config.load() {
                        rankWeightsSection(cfg)
                        regimeWeightsSection(cfg)
                        tracksSection(cfg)
                        sourcesSection(cfg)
                    } else {
                        card("Weights & thresholds") {
                            Text("config.json not found at \(model.paths.root)/config.json.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    denylistCard
                    aliasCard
                    healthSection
                    configCard
                } else {
                    EmptyStateView(icon: "wrench.and.screwdriver",
                                   title: "Backend needs migration",
                                   message: model.schemaError ?? "")
                        .frame(height: 200)
                }
            }
            .padding(MarketUI.pageInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Settings")
        .onAppear {
            rootEdit = model.root
            if !hydrated { hydrate() }
        }
        .task(id: model.dataRevision) {
            await fetchHealth()
            loadLockMeta()
            loadLogs()
        }
    }

    private var header: some View {
        MarketPageHeader(
            eyebrow: "Configuration & operations",
            title: "Settings",
            subtitle: "Tune scoring, curate sources and inspect the pipeline from one controlled surface.",
            systemImage: "gearshape.2.fill",
            tint: Screen.settings.tint
        ) {
            HStack(spacing: 8) {
                if dirty {
                    MarketStatusPill(text: "Unsaved changes", systemImage: "pencil.circle.fill",
                                     color: MarketUI.warning)
                }
                Button { Task { await applyAll() } } label: {
                    Label("Apply & recompute", systemImage: "checkmark.seal.fill")
                }
                .buttonStyle(MarketPrimaryButtonStyle())
                .keyboardShortcut("s", modifiers: .command)
                .help("Apply all weight, threshold and source changes")
                .disabled(!dirty || !model.backendReady)
            }
        }
    }

    // MARK: Backend ROOT

    private var rootCard: some View {
        card("Backend ROOT") {
            HStack {
                TextField("ROOT path", text: $rootEdit)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Button("Apply") { model.applyRoot(rootEdit) }
                    .buttonStyle(MarketPrimaryButtonStyle())
                    .disabled(rootEdit == model.root || rootEdit.isEmpty)
            }
            explain("All backend paths (venv python, appctl.py, market.sqlite, config.json) resolve from this single root.")
            HStack(spacing: 8) {
                MarketStatusPill(text: model.backendReady ? "appctl present" : "appctl missing",
                                 systemImage: model.backendReady ? "checkmark.circle.fill" : "xmark.circle.fill",
                                 color: model.backendReady ? MarketUI.positive : MarketUI.warning)
                let dbPresent = FileManager.default.fileExists(atPath: model.paths.db)
                MarketStatusPill(text: dbPresent ? "database present" : "database missing",
                                 systemImage: dbPresent ? "externaldrive.fill.badge.checkmark" : "externaldrive.badge.xmark",
                                 color: dbPresent ? MarketUI.positive : MarketUI.warning)
            }
        }
    }

    // MARK: Weights & thresholds

    @ViewBuilder
    private func rankWeightsSection(_ cfg: AppConfig) -> some View {
        card("Rank weights") {
            explain("Multiplier applied to a signal based on its source tier (rank 1 = highest tier). Higher weight = that tier counts more toward conviction.")
            ForEach(cfg.rankWeights, id: \.rank) { rw in
                HStack {
                    Text("Rank \(rw.rank)").frame(width: 90, alignment: .leading)
                    Slider(value: rankBinding(rw.rank, fallback: rw.weight), in: 0...1, step: 0.05)
                        .tint(MarketUI.accent)
                        .accessibilityLabel("Rank \(rw.rank) weight")
                    Text(fmt(rankWeights[rw.rank] ?? rw.weight, 2)).monospacedDigit().frame(width: 50)
                }
            }
        }
    }

    @ViewBuilder
    private func regimeWeightsSection(_ cfg: AppConfig) -> some View {
        card("Regime weights") {
            explain("How much each market indicator contributes to the overall bull/bear regime score.")
            ForEach(cfg.regimeWeights, id: \.key) { rw in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(humanLabel(rw.key)).frame(width: 130, alignment: .leading)
                        Slider(value: regimeBinding(rw.key, fallback: rw.weight), in: 0...1, step: 0.05)
                            .tint(MarketUI.accent)
                            .accessibilityLabel("\(humanLabel(rw.key)) regime weight")
                        Text(fmt(regimeWeights[rw.key] ?? rw.weight, 2)).monospacedDigit().frame(width: 50)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tracksSection(_ cfg: AppConfig) -> some View {
        card("Per-track thresholds") {
            explain("Entry/exit and decay rules applied separately to each recommendation track.")
            ForEach(cfg.trackNames, id: \.self) { track in
                VStack(alignment: .leading, spacing: 8) {
                    Text(humanLabel(track)).font(.subheadline.bold())
                    ForEach(thresholdFields, id: \.self) { field in
                        if let v = cfg.trackConfig(track)?[field]?.doubleValue {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(humanLabel(field)).font(.callout)
                                        .frame(width: 230, alignment: .leading)
                                    Stepper(value: trackBinding(track, field, fallback: v),
                                            in: 0...100, step: 1) {
                                        Text(fmt(trackThresholds[track]?[field] ?? v, 0))
                                            .monospacedDigit().frame(width: 40)
                                    }
                                    .accessibilityLabel("\(humanLabel(track)) \(humanLabel(field))")
                                }
                                explain(settingExplanation(field))
                            }
                        }
                    }
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func sourcesSection(_ cfg: AppConfig) -> some View {
        card("Sources") {
            explain("Turn individual data sources on or off and review the handles / channels each one tracks.")
            ForEach(cfg.sources) { src in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Toggle(isOn: sourceBinding(src.key, fallback: src.enabled)) {
                            Text(sourceLabel(src.key)).font(.subheadline.bold())
                        }
                        .toggleStyle(.switch)
                        .tint(MarketUI.accent)
                        Spacer()
                        if let r = src.rank {
                            Text("Rank \(r)").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    if !src.handles.isEmpty {
                        Text("X handles: " + src.handles.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !src.channels.isEmpty {
                        let labels = src.channels.map { src.channelNames[$0] ?? $0 }
                        Text("YouTube: " + labels.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    explain("When off, this source's events are ignored on the next recompute.")
                }
                .padding(.vertical, 2)
                Divider()
            }
        }
    }

    // MARK: Denylist & aliases

    private var denylistCard: some View {
        card("Ticker denylist") {
            HStack {
                TextField("Ticker", text: $newDenyTicker).textFieldStyle(.roundedBorder).frame(width: 120)
                Button("Add") { denylist("denylist-add", newDenyTicker); newDenyTicker = "" }
                    .buttonStyle(MarketSecondaryButtonStyle())
                    .disabled(newDenyTicker.isEmpty || !model.backendReady)
            }
            explain("Tickers on the denylist are excluded from all signals and recommendations. Click the × on a chip to remove it.")
            if let cfg = model.config.load() {
                FlowChips(items: cfg.denylist) { ticker in denylist("denylist-remove", ticker) }
                    .disabled(!model.backendReady)
            }
        }
    }

    private var aliasCard: some View {
        card("Ticker aliases") {
            HStack {
                TextField("Alias", text: $newAlias).textFieldStyle(.roundedBorder).frame(width: 120)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("Canonical", text: $newCanonical).textFieldStyle(.roundedBorder).frame(width: 120)
                Button("Set") {
                    Task {
                        await model.runCommand("alias-set \(newAlias)", "alias-set",
                                               args: ["alias": .string(newAlias.uppercased()),
                                                      "canonical": .string(newCanonical.uppercased())],
                                               recomputes: true)
                        newAlias = ""; newCanonical = ""
                    }
                }
                .buttonStyle(MarketSecondaryButtonStyle())
                .disabled(newAlias.isEmpty || newCanonical.isEmpty || !model.backendReady)
            }
            explain("Map an alternate symbol to its canonical ticker so their signals merge. Calls appctl alias-set/alias-delete (recomputes).")
        }
    }

    // MARK: Pipeline health

    private var healthSection: some View {
        card("Pipeline health") {
            explain("Live status of the data pipeline: schema/generation, source adapters, the run lock, the recent run ledger and the latest log tail.")
            // Schema & generation
            FlowLayout(spacing: 10, lineSpacing: 10) {
                if let m = model.meta {
                    MetricTile(label: "Schema version", value: "\(m.schemaVersion)").frame(width: 150)
                    MetricTile(label: "Supported", value: "\(m.minSupported)–\(m.maxSupported)").frame(width: 130)
                    MetricTile(label: "Generation", value: m.generation.map { "\($0)" } ?? "—").frame(width: 130)
                    MetricTile(label: "Backend", value: model.backendReady ? "Ready" : "Offline",
                               accent: model.backendReady ? .green : .orange).frame(width: 130)
                } else {
                    Text("meta unavailable").foregroundStyle(.secondary)
                }
            }
            Divider()
            // Adapters
            Text("Adapters / last runs").font(.subheadline.bold())
            adaptersBody
            explain("Each source adapter and when it last ingested data (from appctl health).")
            Divider()
            // Run lock
            Text("Run lock").font(.subheadline.bold())
            lockBody
            explain("Whether a pipeline run currently holds the exclusive run lock.")
            Divider()
            // Run ledger
            Text("Run ledger").font(.subheadline.bold())
            AsyncContent(load: loadRuns, revision: model.dataRevision) { runs in
                runLedgerBody(runs)
            }
            explain("The most recent pipeline runs and whether each committed.")
            Divider()
            // Logs
            Text("Recent log tail").font(.subheadline.bold())
            logsBody
            explain("Tail of the latest pipeline log file under \(model.paths.logsDir).")
        }
    }

    @ViewBuilder
    private var adaptersBody: some View {
        if let h = health, h.isOK, let adapters = h.data?["adapters"]?.arrayValue {
            if adapters.isEmpty {
                Text("No adapters reported.").foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(Array(adapters.enumerated()), id: \.offset) { _, a in
                    let enabled = a["enabled"]?.boolValue
                    HStack {
                        Text(sourceLabel(a["source"]?.stringValue ?? a["name"]?.stringValue
                             ?? a["adapter"]?.stringValue ?? "adapter"))
                            .bold().frame(width: 160, alignment: .leading)
                        Text(titleCase(a["status"]?.stringValue
                             ?? (enabled.map { $0 ? "enabled" : "disabled" } ?? "—")))
                            .foregroundStyle(enabled == false ? .tertiary : .secondary)
                        Spacer()
                        Text(a["last_ingested_at"]?.stringValue ?? a["last_run"]?.stringValue
                             ?? a["last_run_at"]?.stringValue ?? "—")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .font(.callout)
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .marketRow()
                }
            }
        } else if let e = healthError {
            Text(e).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Backend health not available yet (appctl.py not installed).")
                .foregroundStyle(.secondary).font(.callout)
        }
    }

    @ViewBuilder
    private var lockBody: some View {
        if let h = health, h.isOK, let lock = h.data?["lock"] {
            Text(prettyJSON(lock)).font(.system(.caption, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: MarketUI.rowRadius).fill(MarketUI.groupedSurface))
        } else if let lm = lockMeta {
            VStack(alignment: .leading) {
                Text("from lock sidecar:").font(.caption).foregroundStyle(.tertiary)
                Text(lm).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: MarketUI.rowRadius).fill(MarketUI.groupedSurface))
            }
        } else {
            Text("No lock held (sidecar absent).").foregroundStyle(.secondary).font(.callout)
        }
    }

    private func runLedgerBody(_ runs: [RunRow]) -> some View {
        Group {
            if runs.isEmpty {
                Text("No runs recorded.").foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(runs) { r in
                    HStack {
                        Text(r.runId).font(.system(.caption, design: .monospaced))
                            .frame(width: 170, alignment: .leading).lineLimit(1)
                        Text(titleCase(r.kind)).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                        Text(r.committedAt ?? "Running…")
                            .foregroundStyle(r.committedAt == nil ? .orange : .secondary)
                        Spacer()
                    }
                    .font(.callout)
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .marketRow()
                }
            }
        }
    }

    @ViewBuilder
    private var logsBody: some View {
        if logTail.isEmpty {
            Text("No logs found under \(model.paths.logsDir).")
                .foregroundStyle(.secondary).font(.callout)
        } else {
            ScrollView {
                Text(logTail).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
            }
            .frame(height: 160)
            .background(RoundedRectangle(cornerRadius: MarketUI.rowRadius).fill(MarketUI.groupedSurface))
            .overlay(RoundedRectangle(cornerRadius: MarketUI.rowRadius)
                .strokeBorder(MarketUI.hairline, lineWidth: 1))
        }
    }

    // MARK: Config version

    private var configCard: some View {
        card("Config version & history") {
            if let cfg = model.config.load() {
                FlowLayout(spacing: 10, lineSpacing: 10) {
                    MetricTile(label: "Config version", value: cfg.configVersion.map { "\($0)" } ?? "—").frame(width: 150)
                    MetricTile(label: "Denylist size", value: "\(cfg.denylist.count)").frame(width: 130)
                    MetricTile(label: "Sources", value: "\(cfg.sources.count)").frame(width: 110)
                }
                explain("Config versions are archived by appctl (keeps the last 50). Restoring an older version is a backend operation.")
            } else {
                Text("config.json not found.").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: bindings (mark dirty on change)

    private func rankBinding(_ rank: Int, fallback: Double) -> Binding<Double> {
        Binding(get: { rankWeights[rank] ?? fallback },
                set: { rankWeights[rank] = $0; dirty = true })
    }
    private func regimeBinding(_ key: String, fallback: Double) -> Binding<Double> {
        Binding(get: { regimeWeights[key] ?? fallback },
                set: { regimeWeights[key] = $0; dirty = true })
    }
    private func trackBinding(_ track: String, _ field: String, fallback: Double) -> Binding<Double> {
        Binding(get: { trackThresholds[track]?[field] ?? fallback },
                set: { trackThresholds[track, default: [:]][field] = $0; dirty = true })
    }
    private func sourceBinding(_ key: String, fallback: Bool) -> Binding<Bool> {
        Binding(get: { sourceEnabled[key] ?? fallback },
                set: { sourceEnabled[key] = $0; dirty = true })
    }

    // MARK: helpers

    /// Inline muted one-line explanation shown under a control (Settings design:
    /// inline text, NOT hover tooltips).
    @ViewBuilder
    private func explain(_ text: String) -> some View {
        if !text.isEmpty {
            Text(text).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func card<C: View>(_ title: String, @ViewBuilder _ body: () -> C) -> some View {
        MarketPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: settingsIcon(title))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MarketUI.accent)
                    MarketSectionLabel(text: title)
                    Spacer()
                }
                body()
            }
        }
    }

    private func settingsIcon(_ title: String) -> String {
        let t = title.lowercased()
        if t.contains("root") { return "externaldrive.fill" }
        if t.contains("rank") { return "list.number" }
        if t.contains("regime") { return "gauge.with.dots.needle.67percent" }
        if t.contains("track") { return "point.topleft.down.to.point.bottomright.curvepath" }
        if t.contains("source") { return "antenna.radiowaves.left.and.right" }
        if t.contains("deny") { return "nosign" }
        if t.contains("alias") { return "arrow.triangle.swap" }
        if t.contains("health") { return "heart.text.square.fill" }
        if t.contains("version") { return "clock.arrow.circlepath" }
        return "slider.horizontal.3"
    }

    private func hydrate() {
        hydrated = true
        guard let cfg = model.config.load() else { return }
        for rw in cfg.rankWeights { rankWeights[rw.rank] = rw.weight }
        for rw in cfg.regimeWeights { regimeWeights[rw.key] = rw.weight }
        for t in cfg.trackNames {
            for f in thresholdFields {
                if let v = cfg.trackConfig(t)?[f]?.doubleValue {
                    trackThresholds[t, default: [:]][f] = v
                }
            }
        }
        for s in cfg.sources { sourceEnabled[s.key] = s.enabled }
    }

    private func applyAll() async {
        var patch: [String: JSONValue] = [:]
        for (rank, w) in rankWeights { patch["rank_weights.\(rank)"] = .number(w) }
        for (k, w) in regimeWeights { patch["regime.weights.\(k)"] = .number(w) }
        for (track, fields) in trackThresholds {
            for (f, v) in fields { patch["tracks.\(track).\(f)"] = .number(v) }
        }
        for (key, on) in sourceEnabled { patch["sources.\(key).enabled"] = .bool(on) }

        await model.runCommand("set-config (Apply)", "set-config",
                               args: ["patch": .object(patch)], recomputes: true)
        if case .succeeded = model.lastCommand { dirty = false }
    }

    private func denylist(_ cmd: String, _ ticker: String) {
        let t = ticker.uppercased()
        Task { await model.runCommand("\(cmd) \(t)", cmd, args: ["ticker": .string(t)], recomputes: true) }
    }

    private func loadRuns() async -> Result<[RunRow], Error> {
        let repo = model.repo
        return await loadAsync { try repo.recentRuns(limit: 25) }
    }

    private func fetchHealth() async {
        #if IVO_PREVIEW
        await MainActor.run {
            health = nil
            healthError = "Live appctl health is suppressed in the isolated preview build."
        }
        return
        #else
        guard model.backendReady else { health = nil; healthError = nil; return }
        do {
            let r = try await model.appctl.run("health")
            await MainActor.run { health = r; healthError = r.isOK ? nil : (r.message ?? "health error") }
        } catch {
            await MainActor.run { healthError = "\(error)" }
        }
        #endif
    }

    private func loadLockMeta() {
        lockMeta = (try? String(contentsOfFile: model.paths.lockMeta, encoding: .utf8))
    }

    private func loadLogs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: model.paths.logsDir) else { logTail = ""; return }
        let logs = files.filter { $0.hasSuffix(".log") || $0.hasSuffix(".jsonl") }.sorted()
        guard let last = logs.last else { logTail = ""; return }
        let path = model.paths.logsDir + "/" + last
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { logTail = ""; return }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        logTail = lines.suffix(120).joined(separator: "\n")
    }

    private func prettyJSON(_ v: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(v),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: pretty, encoding: .utf8) else {
            return v.stringValue ?? "—"
        }
        return s
    }
}

/// Wrapping chip layout for denylist tokens; tapping the × calls the remove action.
struct FlowChips: View {
    let items: [String]
    let onRemove: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 4) {
                    Text(item).font(.system(.caption, design: .monospaced))
                    Button { onRemove(item) } label: {
                        Label("Remove \(item) from denylist", systemImage: "xmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .font(.caption)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Remove \(item) from denylist")
                }
                .padding(.leading, 9).padding(.trailing, 3).padding(.vertical, 2)
                .background(Capsule().fill(MarketUI.surfaceRaised))
                .overlay(Capsule().strokeBorder(MarketUI.hairline, lineWidth: 1))
            }
        }
    }
}
