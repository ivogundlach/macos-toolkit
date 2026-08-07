import SwiftUI
import UniformTypeIdentifiers
import MarketCore

// View 6 — Watchlists & positions: list + add/edit/delete forms calling appctl
// position-* / watchlist-*. Decimal quantities stay as strings (Swift no arithmetic).
// Also imports TradingView-style .txt exports (comma-separated EXCHANGE:SYMBOL).

struct PositionsData {
    let positions: [Position]
    let watchlists: [Watchlist]
}

struct PositionsView: View {
    /// Single source of truth for the position add/edit sheet — drives
    /// `.sheet(item:)` so the form always receives the right value. A plain
    /// `.sheet(isPresented:)` + separate `editingPosition` state could present
    /// before the state propagated, showing an empty "Add" form on Edit.
    private enum PositionSheet: Identifiable {
        case add
        case edit(Position)
        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let p): return "edit-\(p.id)"
            }
        }
    }

    /// Add/edit sheet for watchlists, mirroring `PositionSheet` so Edit always
    /// receives the right watchlist value via `.sheet(item:)`.
    private enum WatchlistSheet: Identifiable {
        case add
        case edit(Watchlist)
        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let w): return "edit-\(w.id)"
            }
        }
    }

    /// A delete awaiting confirmation. Drives one `.confirmationDialog` so a
    /// misclick on Delete can't silently destroy a row.
    private enum PendingDelete: Identifiable {
        case position(Position)
        case watchlist(Watchlist)
        var id: String {
            switch self {
            case .position(let p): return "p-\(p.id)"
            case .watchlist(let w): return "w-\(w.id)"
            }
        }
        var title: String {
            switch self {
            case .position(let p): return "Delete position \(p.symbol)?"
            case .watchlist(let w): return "Delete watchlist \(w.name)?"
            }
        }
    }

    @EnvironmentObject var model: AppModel
    @ViewState private var positionSheet: PositionSheet?
    @ViewState private var watchlistSheet: WatchlistSheet?
    @ViewState private var pendingDelete: PendingDelete?
    @ViewState private var showPositionsImporter = false
    @ViewState private var showWatchlistImporter = false

    var body: some View {
        BackendGate(model: model) {
            AsyncContent(load: load, revision: model.dataRevision) { data in
                ScrollView {
                    VStack(alignment: .leading, spacing: MarketUI.regionSpacing) {
                        MarketPageHeader(
                            eyebrow: "Portfolio workspace",
                            title: "Watchlists & Positions",
                            subtitle: "Maintain holdings and candidate lists without leaving the research terminal.",
                            systemImage: "list.bullet.rectangle",
                            tint: Screen.positions.tint
                        ) {
                            HStack(spacing: 7) {
                                MarketStatusPill(text: "\(data.positions.count) positions",
                                                 systemImage: "briefcase.fill", color: MarketUI.accent)
                                MarketStatusPill(text: "\(data.watchlists.count) lists",
                                                 systemImage: "eye.fill", color: .secondary)
                            }
                        }
                        if !model.backendReady {
                            MarketPanel {
                                Label("Command bridge offline — portfolio data remains readable, but changes are disabled.",
                                      systemImage: "bolt.slash.fill")
                                    .font(.callout).foregroundStyle(MarketUI.warning)
                            }
                        }
                        positionsSection(data.positions)
                        watchlistsSection(data.watchlists)
                    }
                    .padding(MarketUI.pageInset)
                }
            }
        }
        .navigationTitle("Watchlists & positions")
        .sheet(item: $positionSheet) { sheet in
            switch sheet {
            case .add: PositionForm(model: model, existing: nil) { }
            case .edit(let p): PositionForm(model: model, existing: p) { }
            }
        }
        .sheet(item: $watchlistSheet) { sheet in
            switch sheet {
            case .add: WatchlistForm(model: model, existing: nil)
            case .edit(let w): WatchlistForm(model: model, existing: w)
            }
        }
        .confirmationDialog(
            pendingDelete?.title ?? "Delete",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { item in
            Button("Delete", role: .destructive) { confirmDelete(item) }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("This can't be undone.")
        }
        .fileImporter(isPresented: $showPositionsImporter,
                      allowedContentTypes: [.plainText, .text],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importPositions(urls) }
        }
        .fileImporter(isPresented: $showWatchlistImporter,
                      allowedContentTypes: [.plainText, .text],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importWatchlists(urls) }
        }
    }

    @ViewBuilder
    private func positionsSection(_ positions: [Position]) -> some View {
        MarketPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        MarketSectionLabel(text: "Positions")
                        Text("Current holdings and cost context").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { showPositionsImporter = true } label: {
                        Label("Import .txt", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(MarketSecondaryButtonStyle())
                    .help("Import TradingView symbols as zero-quantity positions")
                    .disabled(!model.backendReady)
                    Button { positionSheet = .add } label: {
                        Label("Add position", systemImage: "plus")
                    }
                    .buttonStyle(MarketPrimaryButtonStyle())
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!model.backendReady)
                }
                if positions.isEmpty {
                    inlineEmpty(icon: "briefcase", title: "No positions",
                                message: "Add a holding or import a TradingView text export.")
                } else {
                    ViewThatFits(in: .horizontal) {
                        widePositions(positions)
                        compactPositions(positions)
                    }
                }
            }
        }
    }

    private func widePositions(_ positions: [Position]) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                MarketTableHeader(title: "Symbol").frame(width: 72)
                MarketTableHeader(title: "Quantity").frame(width: 104)
                MarketTableHeader(title: "Cost basis").frame(width: 104)
                MarketTableHeader(title: "Currency").frame(width: 66)
                MarketTableHeader(title: "Source").frame(width: 72)
                Spacer()
                MarketTableHeader(title: "Actions", alignment: .trailing).frame(width: 92)
            }
            .padding(.horizontal, 7)
            Divider().opacity(0.6)
            ForEach(positions) { p in
                HStack(spacing: 8) {
                    Text(p.symbol).font(.system(.callout, design: .monospaced).bold())
                        .frame(width: 72, alignment: .leading)
                    Text(p.quantity).monospacedDigit().frame(width: 104, alignment: .leading)
                    Text(p.costBasis ?? "—").foregroundStyle(.secondary)
                        .frame(width: 104, alignment: .leading)
                    Text(p.currency).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
                    Text(titleCase(p.provenance)).font(.caption).foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)
                    Spacer()
                    positionActions(p)
                }
                .font(.callout)
                .padding(.horizontal, 7).padding(.vertical, 7)
                .marketRow()
                .accessibilityElement(children: .contain)
            }
        }
    }

    private func compactPositions(_ positions: [Position]) -> some View {
        VStack(spacing: 3) {
            ForEach(positions) { p in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.symbol).font(.system(.callout, design: .monospaced).bold())
                        Text("\(titleCase(p.provenance)) · \(p.currency)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Qty \(p.quantity)").font(.callout).monospacedDigit()
                        Text(p.costBasis.map { "Cost \($0)" } ?? "No cost basis")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    positionActions(p)
                }
                .padding(.horizontal, 7).padding(.vertical, 7)
                .marketRow()
                .accessibilityElement(children: .contain)
            }
        }
    }

    private func positionActions(_ p: Position) -> some View {
        HStack(spacing: 8) {
            Button("Edit") { positionSheet = .edit(p) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Edit position \(p.symbol)")
                .disabled(!model.backendReady)
            Button(role: .destructive) { pendingDelete = .position(p) } label: { Text("Delete") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete position \(p.symbol)")
                .disabled(!model.backendReady)
        }
        .frame(width: 92, alignment: .trailing)
    }

    @ViewBuilder
    private func watchlistsSection(_ watchlists: [Watchlist]) -> some View {
        MarketPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        MarketSectionLabel(text: "Watchlists")
                        Text("Named candidate and holding universes").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { showWatchlistImporter = true } label: {
                        Label("Import .txt", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(MarketSecondaryButtonStyle())
                    .help("Create one watchlist per TradingView text file")
                    .disabled(!model.backendReady)
                    Button { watchlistSheet = .add } label: { Label("Add watchlist", systemImage: "plus") }
                        .buttonStyle(MarketPrimaryButtonStyle())
                        .disabled(!model.backendReady)
                }
                if watchlists.isEmpty {
                    inlineEmpty(icon: "eye", title: "No watchlists",
                                message: "Build a candidate list manually or import one from TradingView.")
                } else {
                    VStack(spacing: 3) {
                        ForEach(watchlists) { w in
                            HStack(alignment: .center, spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: MarketUI.controlRadius)
                                        .fill(MarketUI.accentSoft)
                                    Image(systemName: w.kind.lowercased() == "holding" ? "briefcase.fill" : "eye.fill")
                                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(MarketUI.accent)
                                }
                                .frame(width: 32, height: 32)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(w.name).font(.callout.weight(.semibold))
                                        MarketStatusPill(text: titleCase(w.kind), systemImage: "tag.fill",
                                                         color: .secondary)
                                        if w.stale {
                                            MarketStatusPill(text: "Stale", systemImage: "clock.badge.exclamationmark",
                                                             color: MarketUI.warning)
                                        }
                                    }
                                    Text(w.tickers.isEmpty ? "No tickers" : w.tickers.joined(separator: ", "))
                                        .font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Button("Edit") { watchlistSheet = .edit(w) }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Edit watchlist \(w.name)")
                                    .disabled(!model.backendReady)
                                Button(role: .destructive) { pendingDelete = .watchlist(w) } label: { Text("Delete") }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Delete watchlist \(w.name)")
                                    .disabled(!model.backendReady)
                            }
                            .padding(.horizontal, 7).padding(.vertical, 7)
                            .marketRow()
                        }
                    }
                }
            }
        }
    }

    private func inlineEmpty(icon: String, title: String, message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(MarketUI.accent)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: MarketUI.controlRadius).fill(MarketUI.accentSoft))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: MarketUI.rowRadius).fill(MarketUI.groupedSurface))
        .accessibilityElement(children: .combine)
    }

    private func deletePosition(_ p: Position) {
        Task { await model.runCommand("position-delete \(p.symbol)", "position-delete",
                                      args: ["id": .number(Double(p.id))]) }
    }
    private func deleteWatchlist(_ w: Watchlist) {
        Task { await model.runCommand("watchlist-delete \(w.name)", "watchlist-delete",
                                      args: ["id": .number(Double(w.id))]) }
    }

    private func confirmDelete(_ item: PendingDelete) {
        switch item {
        case .position(let p): deletePosition(p)
        case .watchlist(let w): deleteWatchlist(w)
        }
        pendingDelete = nil
    }

    private func load() async -> Result<PositionsData, Error> {
        let repo = model.repo
        return await loadAsync {
            PositionsData(positions: try repo.positions(), watchlists: try repo.watchlists())
        }
    }

    // MARK: - .txt import (TradingView exports)

    /// One `position-set` per symbol. TradingView exports carry no share count, so
    /// quantity defaults to "0" (an editable placeholder); provenance "import" with
    /// an empty account keeps re-imports idempotent (upsert key is symbol+account+provenance).
    private func importPositions(_ urls: [URL]) {
        Task {
            var imported = 0, failed = 0
            for url in urls {
                guard let text = TickerImport.read(url) else { failed += 1; continue }
                for sym in TickerImport.tickers(from: text) {
                    let resp = await model.importRun("position-set", args: [
                        "symbol": .string(sym),
                        "quantity": .string("0"),
                        "currency": .string("USD"),
                        "account": .string(""),
                        "provenance": .string("import"),
                    ])
                    if resp { imported += 1 } else { failed += 1 }
                }
            }
            model.finishImport(label: "Imported \(imported) position(s)", imported: imported, failed: failed)
        }
    }

    /// One `watchlist-set` per file; name from the filename, kind "candidate".
    private func importWatchlists(_ urls: [URL]) {
        Task {
            var imported = 0, failed = 0
            for url in urls {
                guard let text = TickerImport.read(url) else { failed += 1; continue }
                let name = TickerImport.watchlistName(from: url.lastPathComponent)
                let tickers = TickerImport.tickers(from: text).map { JSONValue.string($0) }
                let resp = await model.importRun("watchlist-set", args: [
                    "name": .string(name),
                    "kind": .string("candidate"),
                    "tickers": .array(tickers),
                    "provenance": .string("manual"),
                ])
                if resp { imported += 1 } else { failed += 1 }
            }
            model.finishImport(label: "Imported \(imported) watchlist(s)", imported: imported, failed: failed)
        }
    }
}

struct PositionForm: View {
    @ObservedObject var model: AppModel
    let existing: Position?
    let onDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss

    @ViewState private var symbol = ""
    @ViewState private var quantity = ""
    @ViewState private var costBasis = ""
    @ViewState private var currency = "USD"
    @ViewState private var account = ""

    private var draft: PositionFormDraft {
        PositionFormDraft(
            symbol: symbol,
            quantity: quantity,
            costBasis: costBasis,
            currency: currency,
            account: account)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader(title: existing == nil ? "Add Position" : "Edit Position",
                        subtitle: existing == nil ? "Create a manually managed holding." : "Update this holding atomically.",
                        icon: "briefcase.fill")
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                MarketSectionLabel(text: "Holding details")
                formRow("Symbol", help: "Ticker symbol") {
                    TextField("NVDA", text: $symbol)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Position symbol")
                }
                formRow("Quantity", help: "Decimal value") {
                    TextField("0", text: $quantity)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Position quantity")
                }
                formRow("Cost basis", help: "Optional") {
                    TextField("0.00", text: $costBasis)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Position cost basis")
                }
                formRow("Currency", help: "Defaults to USD") {
                    TextField("USD", text: $currency)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Position currency")
                }
                formRow("Account", help: "Optional") {
                    TextField("Brokerage", text: $account)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Position account")
                }
                Label(draft.canSave ? "Ready to save" : "Enter a symbol and valid numeric quantity.",
                      systemImage: draft.canSave ? "checkmark.circle" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(draft.canSave ? MarketUI.positive : .secondary)
            }
            .padding(18)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { onDismiss(); dismiss() }
                    .buttonStyle(MarketSecondaryButtonStyle())
                Button { save() } label: { Label("Save position", systemImage: "checkmark") }
                    .buttonStyle(MarketPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canSave)
            }
            .padding(14)
        }
        .frame(width: 430)
        .refractiveCanvas(forceDark: true)
        .onAppear {
            if let e = existing {
                symbol = e.symbol; quantity = e.quantity; costBasis = e.costBasis ?? ""
                currency = e.currency; account = e.account ?? ""
            }
        }
    }

    private func sheetHeader(title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MarketUI.accent)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: MarketUI.controlRadius).fill(MarketUI.accentSoft))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private func formRow<Content: View>(_ label: String, help: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.callout.weight(.medium))
                Text(help).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(width: 112, alignment: .leading)
            content().frame(maxWidth: .infinity)
        }
    }

    private func save() {
        let draft = draft
        Task {
            switch planPositionSave(existingID: existing?.id, draft: draft) {
            case .abort(let message):
                if let e = existing {
                    model.failCommand(label: "Edit \(e.symbol)", message: message)
                }
            case .set(let payload):
                await model.runCommand(
                    "position-set \(payload.symbol)", "position-set",
                    args: positionArgs(payload))
                onDismiss(); dismiss()
            case .replace(let id, let payload):
                var args = positionArgs(payload)
                args["id"] = .number(Double(id))
                await model.runCommand(
                    "position-replace \(payload.symbol)", "position-replace",
                    args: args)
                onDismiss(); dismiss()
            }
        }
    }

    private func positionArgs(_ payload: PositionFormPayload) -> [String: JSONValue] {
        var args: [String: JSONValue] = [
            "symbol": .string(payload.symbol),
            "quantity": .string(payload.quantity),
            "currency": .string(payload.currency),
            "provenance": .string("manual")
        ]
        if let costBasis = payload.costBasis { args["cost_basis"] = .string(costBasis) }
        if let account = payload.account { args["account"] = .string(account) }
        return args
    }
}

struct WatchlistForm: View {
    @ObservedObject var model: AppModel
    let existing: Watchlist?
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @ViewState private var kind = "candidate"
    @ViewState private var tickers = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "eye.fill").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MarketUI.accent)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: MarketUI.controlRadius).fill(MarketUI.accentSoft))
                VStack(alignment: .leading, spacing: 1) {
                    Text(existing == nil ? "Add Watchlist" : "Edit Watchlist").font(.title3.weight(.semibold))
                    Text("Group tickers into a focused research universe.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                MarketSectionLabel(text: "List details")
                HStack(spacing: 12) {
                    Text("Name").font(.callout.weight(.medium)).frame(width: 92, alignment: .leading)
                    TextField("Core compounders", text: $name)
                        .textFieldStyle(.roundedBorder)
                        // ponytail: name is the (name, provenance) upsert key, so editing it
                        // would create a second row. Read-only on edit — rename = delete +
                        // re-add — rather than add a watchlist-replace command for a rare act.
                        .disabled(existing != nil)
                        .accessibilityLabel("Watchlist name")
                }
                HStack(spacing: 12) {
                    Text("Kind").font(.callout.weight(.medium)).frame(width: 92, alignment: .leading)
                    Picker("Watchlist kind", selection: $kind) {
                        Text("Candidate").tag("candidate"); Text("Holding").tag("holding")
                    }
                    .labelsHidden().pickerStyle(.segmented)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Tickers").font(.callout.weight(.medium)).frame(width: 92, alignment: .leading)
                    TextField("NVDA, MSFT, AMZN", text: $tickers)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Watchlist tickers, comma separated")
                }
                if existing != nil {
                    Label("The name is the stable backend key and cannot be changed while editing.",
                          systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(18)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(MarketSecondaryButtonStyle())
                Button { save() } label: { Label("Save watchlist", systemImage: "checkmark") }
                    .buttonStyle(MarketPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)
        }
        .frame(width: 430)
        .refractiveCanvas(forceDark: true)
        .onAppear {
            if let e = existing {
                name = e.name; kind = e.kind
                tickers = e.tickers.joined(separator: ", ")
            }
        }
    }

    private func save() {
        let list = tickers.split(separator: ",").map {
            JSONValue.string($0.trimmingCharacters(in: .whitespaces).uppercased())
        }
        let args: [String: JSONValue] = [
            "name": .string(name),
            "kind": .string(kind),
            "tickers": .array(list),
            "provenance": .string(existing?.provenance ?? "manual")
        ]
        Task {
            await model.runCommand("watchlist-set \(name)", "watchlist-set", args: args)
            dismiss()
        }
    }
}

/// Parses TradingView-style `.txt` exports: comma/space/newline-separated
/// `EXCHANGE:SYMBOL` tokens on (usually) a single line.
enum TickerImport {
    /// Read a (possibly security-scoped) file as UTF-8 text.
    static func read(_ url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Bare, upper-cased, de-duplicated tickers (exchange prefix stripped),
    /// preserving first-seen order. Blank and `#`-comment tokens are skipped.
    static func tickers(from text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ", \t\r\n;")
        var seen = Set<String>()
        var out: [String] = []
        for raw in text.components(separatedBy: separators) {
            var tok = raw.trimmingCharacters(in: .whitespaces)
            if tok.isEmpty || tok.hasPrefix("#") { continue }
            if let colon = tok.lastIndex(of: ":") {       // NASDAQ:NVDA -> NVDA
                tok = String(tok[tok.index(after: colon)...])
            }
            tok = tok.uppercased()
            if !tok.isEmpty && seen.insert(tok).inserted { out.append(tok) }
        }
        return out
    }

    /// Cleans a TradingView export filename into a watchlist name: drops the
    /// extension and the trailing `_<hash>`, strips leading `• _ -` decoration,
    /// and turns underscores into spaces. `_Core Stocks_843a9.txt` -> "Core Stocks".
    static func watchlistName(from filename: String) -> String {
        var n = filename
        if let dot = n.lastIndex(of: ".") { n = String(n[..<dot]) }
        if let r = n.range(of: "_[0-9A-Fa-f]{5}$", options: .regularExpression) {
            n.removeSubrange(r)
        }
        n = n.trimmingCharacters(in: CharacterSet(charactersIn: "•_- "))
        n = n.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "Imported" : n
    }
}
