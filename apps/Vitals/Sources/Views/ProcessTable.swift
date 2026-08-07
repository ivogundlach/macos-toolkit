import SwiftUI
import AppKit

/// The process rows, as a real `NSTableView`.
///
/// This replaced a `LazyVStack` of SwiftUI rows, and the reason is measured rather
/// than stylistic. `LazyVStack` is lazy about *creating* rows, not about keeping
/// them: with twelve columns and ~40 rows on screen it holds ~480 `Text` nodes, and
/// SwiftUI re-lays-out and re-renders that tree on the frames it moves. Six seconds
/// of scrolling cost 3.3–4.3 s of main-thread time and pushed the GPU from 2.5% to
/// 20%, with a third of frames arriving late — which is why the view could not keep
/// up with the scroller and showed a position you were no longer at.
///
/// `NSTableView` reuses row and cell views, so the cost is bounded by what is
/// visible rather than by what is scrolled past, and the scrolling itself is
/// AppKit's rather than a SwiftUI animation driving layout.
///
/// Only the rows moved. The header stays SwiftUI — it already carries the kicker
/// styling, click-to-sort, drag-to-reorder and the show/hide menu, and none of that
/// was costing anything, so `headerView` here is deliberately nil.
struct ProcessTable: NSViewRepresentable {
    var rows: [ProcRow]
    var columns: [ProcColumn]
    var widths: [CGFloat]
    var userName: (UInt32) -> String
    var fontSize: CGFloat
    var rowHeight: CGFloat
    var bandRun: Int
    @Binding var selected: Int32?
    var onInspect: (ProcRow) -> Void
    var onQuit: (ProcRow, Bool) -> Void
    var onConfirmKill: (ProcRow) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        // `.regular`, not `.none`. With `.none` AppKit skips row selection drawing
        // altogether, so an overridden `drawSelection` is simply never called and
        // the selected row looks identical to every other row. The override still
        // decides what selection looks like — this only decides that it is drawn.
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = false    // the SwiftUI header owns ordering
        table.allowsColumnResizing = false
        table.rowSizeStyle = .custom
        // Zero horizontal spacing, and the inter-column gap carried inside the
        // column instead. AppKit distributes `intercellSpacing` around cells by its
        // own convention — half before the first column, by most accounts — and the
        // SwiftUI header spaces its columns with a plain `HStack`. Rather than
        // match a convention by guessing at a few points of offset, the column is
        // made `width + gap` wide and the cell keeps `gap` clear on its trailing
        // edge, which puts column i at the same x in both views by construction.
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.menu = context.coordinator.makeMenu()

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        // The same leading inset the SwiftUI header pads itself by. Applied to the
        // scroll view rather than to the first cell: insetting the cell would eat
        // into that column's width and shift only its own text, leaving every
        // column after it where it was.
        scroll.contentInsets = NSEdgeInsets(top: VitalsTheme.padXS,
                                            left: VitalsTheme.tableInset,
                                            bottom: VitalsTheme.padXS, right: 0)

        context.coordinator.table = table
        context.coordinator.sync(from: self)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.sync(from: self)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: NSTableView?
        private var parent: ProcessTable?
        private var columnIdentifiers: [String] = []

        func sync(from parent: ProcessTable) {
            let previous = self.parent
            self.parent = parent
            guard let table else { return }

            let wanted = parent.columns.map(\.rawValue)
            if wanted != columnIdentifiers {
                rebuildColumns(table: table, parent: parent)
                columnIdentifiers = wanted
            } else if let previous, previous.widths != parent.widths {
                for (index, column) in table.tableColumns.enumerated()
                where index < parent.widths.count {
                    column.width = parent.widths[index]
                }
            }

            if table.rowHeight != parent.rowHeight {
                table.rowHeight = parent.rowHeight
            }

            // Reload only when the data actually changed. `updateNSView` runs for
            // any state the parent touches, including the ones that change while
            // scrolling, and reloading mid-scroll is what a table must never do.
            let changed = previous.map { !$0.rows.identical(to: parent.rows) } ?? true
            if changed {
                table.reloadData()
                restoreSelection(table: table, parent: parent)
            } else if previous?.selected != parent.selected {
                restoreSelection(table: table, parent: parent)
            }
        }

        private func rebuildColumns(table: NSTableView, parent: ProcessTable) {
            for column in table.tableColumns { table.removeTableColumn(column) }
            for (index, column) in parent.columns.enumerated() {
                let native = NSTableColumn(
                    identifier: NSUserInterfaceItemIdentifier(column.rawValue))
                let base = index < parent.widths.count ? parent.widths[index] : column.width
                let isLast = index == parent.columns.count - 1
                native.width = base + (isLast ? 0 : VitalsTheme.padS)
                native.minWidth = native.width
                native.maxWidth = native.width
                native.title = column.title
                table.addTableColumn(native)
            }
            table.reloadData()
        }

        private func restoreSelection(table: NSTableView, parent: ProcessTable) {
            guard let selected = parent.selected,
                  let row = parent.rows.firstIndex(where: { $0.pid == selected }) else {
                table.deselectAll(nil)
                return
            }
            if table.selectedRow != row {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }

        // MARK: Data

        func numberOfRows(in tableView: NSTableView) -> Int { parent?.rows.count ?? 0 }

        func tableView(_ tableView: NSTableView,
                       viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let parent, row < parent.rows.count,
                  let identifier = tableColumn?.identifier.rawValue,
                  let column = ProcColumn(rawValue: identifier) else { return nil }

            let reuse = NSUserInterfaceItemIdentifier("cell")
            let cell = tableView.makeView(withIdentifier: reuse, owner: self) as? ProcCellView
                ?? ProcCellView(identifier: reuse)

            let procRow = parent.rows[row]
            cell.configure(text: ProcCell.text(procRow, column,
                                               user: parent.userName(procRow.counters.uid)),
                           color: NSColor(ProcCell.color(procRow, column)),
                           alignment: column.alignment == .trailing ? .right : .left,
                           fontSize: parent.fontSize,
                           leadingInset: 0,
                           trailingInset: parent.columns.last == column ? 0 : VitalsTheme.padS,
                           locked: column == .name && !procRow.readable)
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let reuse = NSUserInterfaceItemIdentifier("row")
            let view = tableView.makeView(withIdentifier: reuse, owner: self) as? ProcRowView
                ?? ProcRowView(identifier: reuse)
            let run = max(1, parent?.bandRun ?? 1)
            view.banded = (row / run) % 2 == 1
            return view
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table, let current = parent else { return }
            let row = table.selectedRow
            let pid: Int32? = (row >= 0 && row < current.rows.count) ? current.rows[row].pid : nil
            if current.selected != pid { parent?.selected = pid }
        }

        func currentRow(at index: Int) -> ProcRow? {
            guard let parent, index >= 0, index < parent.rows.count else { return nil }
            return parent.rows[index]
        }

        // MARK: Actions

        @objc func doubleClicked(_ sender: Any?) {
            guard let table, let parent else { return }
            let row = table.clickedRow
            guard row >= 0, row < parent.rows.count else { return }
            parent.onInspect(parent.rows[row])
        }

        private func clickedRow() -> ProcRow? {
            guard let table, let parent else { return nil }
            let row = table.clickedRow
            guard row >= 0, row < parent.rows.count else { return nil }
            return parent.rows[row]
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            return menu
        }

        @objc func menuGetInfo(_ sender: Any?) {
            guard let row = clickedRow() else { return }
            parent?.selected = row.pid
            parent?.onInspect(row)
        }

        @objc func menuQuit(_ sender: Any?) {
            guard let row = clickedRow() else { return }
            parent?.onQuit(row, false)
        }

        @objc func menuForceQuit(_ sender: Any?) {
            guard let row = clickedRow() else { return }
            parent?.onConfirmKill(row)
        }

        @objc func menuCopyPath(_ sender: Any?) {
            guard let row = clickedRow() else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.counters.path, forType: .string)
        }

        @objc func menuShowInFinder(_ sender: Any?) {
            guard let row = clickedRow(), !row.counters.path.isEmpty else { return }
            NSWorkspace.shared.activateFileViewerSelecting(
                [URL(fileURLWithPath: row.counters.path)])
        }

        @objc func menuCopyPID(_ sender: Any?) {
            guard let row = clickedRow() else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(row.pid), forType: .string)
        }
    }
}

extension ProcessTable.Coordinator: NSMenuDelegate {
    /// Built per open, because the items depend on which row was clicked and
    /// whether that process has a readable path.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let row = clickedRowForMenu() else { return }

        let title = NSMenuItem(title: "\(row.name) — PID \(row.pid)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Get Info", action: #selector(menuGetInfo(_:)),
                                keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(menuQuit(_:)),
                                keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Force Quit", action: #selector(menuForceQuit(_:)),
                                keyEquivalent: ""))
        menu.addItem(.separator())
        if !row.counters.path.isEmpty {
            menu.addItem(NSMenuItem(title: "Copy Path", action: #selector(menuCopyPath(_:)),
                                    keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Show in Finder",
                                    action: #selector(menuShowInFinder(_:)), keyEquivalent: ""))
        }
        menu.addItem(NSMenuItem(title: "Copy PID", action: #selector(menuCopyPID(_:)),
                                keyEquivalent: ""))
        for item in menu.items where item.action != nil { item.target = self }
    }

    private func clickedRowForMenu() -> ProcRow? {
        guard let table else { return nil }
        let row = table.clickedRow
        guard row >= 0 else { return nil }
        return currentRow(at: row)
    }
}

/// One row's background. Banding and selection are drawn here rather than per cell,
/// so a row is one fill instead of one fill per column.
final class ProcRowView: NSTableRowView {
    var banded = false { didSet { if banded != oldValue { needsDisplay = true } } }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        // One layer per row instead of one per cell. Inside SwiftUI the whole
        // hierarchy is layer-backed, so each cell's text field was its own layer to
        // composite — thirteen columns across every visible row.
        canDrawSubviewsIntoLayer = true
        // Keep the rasterized row cached across scrolls. A layer-backed view inside
        // SwiftUI otherwise redraws when its visible rect moves, which turns every
        // scrolled frame into a full re-render of every visible row instead of a
        // composite of layers whose contents never changed.
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func drawBackground(in dirtyRect: NSRect) {
        if banded {
            NSColor(VitalsTheme.rowBand).setFill()
            bounds.fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        // Two cues, because one is not enough here. The fill has to stay light —
        // it sits over glass and behind mono numerals that must keep their
        // contrast — and a light fill alone reads as another banding stripe. The
        // accent bar on the leading edge is what actually says "this row".
        NSColor.controlAccentColor.withAlphaComponent(isEmphasized ? 0.26 : 0.14).setFill()
        bounds.fill()
        NSColor.controlAccentColor.withAlphaComponent(isEmphasized ? 0.95 : 0.5).setFill()
        NSRect(x: bounds.minX, y: bounds.minY, width: 3, height: bounds.height).fill()
    }
}

/// One cell. A single text field, plus a lock badge for processes whose counters
/// are unreadable — the same two elements the SwiftUI row had, without the layout
/// tree around them.
final class ProcCellView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var lock: NSImageView?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.drawsBackground = false
        label.isBordered = false
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var leadingInset: CGFloat = 0
    private var trailingInset: CGFloat = 0

    func configure(text: String, color: NSColor, alignment: NSTextAlignment,
                   fontSize: CGFloat, leadingInset: CGFloat, trailingInset: CGFloat,
                   locked: Bool) {
        self.leadingInset = leadingInset
        self.trailingInset = trailingInset
        label.stringValue = text
        label.textColor = color
        label.alignment = alignment
        label.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        if locked {
            if lock == nil {
                let image = NSImageView(image: NSImage(
                    systemSymbolName: "lock.fill",
                    accessibilityDescription: "Counters unreadable") ?? NSImage())
                image.contentTintColor = NSColor(VitalsTheme.warn)
                image.symbolConfiguration = NSImage.SymbolConfiguration(
                    pointSize: max(7, fontSize - 4), weight: .regular)
                addSubview(image)
                lock = image
            }
            lock?.isHidden = false
        } else {
            lock?.isHidden = true
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let lockWidth: CGFloat = (lock?.isHidden == false) ? bounds.height * 0.6 + 4 : 0
        if let lock, !lock.isHidden {
            lock.frame = NSRect(x: leadingInset, y: 0,
                                width: lockWidth - 4, height: bounds.height)
        }
        // NSTextFieldCell insets its text ~2pt; undo it so a column of numbers lines
        // up with the header above it, exactly as the header cell does.
        label.frame = NSRect(x: leadingInset + lockWidth - 2, y: 0,
                             width: max(0, bounds.width - leadingInset - lockWidth
                                            - trailingInset + 4),
                             height: bounds.height)
    }
}

/// The text and colour of one cell.
///
/// Free functions rather than methods on a view, because both the table and any
/// future exporter want the same answer, and because a cell's contents must not
/// depend on a view existing.
enum ProcCell {
    static func text(_ row: ProcRow, _ column: ProcColumn, user: String) -> String {
        switch column {
        case .pid: return String(row.pid)
        case .ppid: return String(row.counters.ppid)
        case .name: return row.name
        case .user: return user
        case .uid: return String(row.counters.uid)
        case .path: return row.counters.path.isEmpty ? "—" : row.counters.path
        case .measured: return row.readable ? "yes" : "needs helper"
        case .status: return Fmt.processStatus(row.counters.status)
        case .started:
            guard row.counters.startAbs > 0 else { return "—" }
            return Fmt.shortDateTime(Date(timeIntervalSince1970:
                Double(row.counters.startAbs) / 1_000_000))
        case .cpu: return Fmt.percent(row.cpuPercent)
        case .cpuTime: return Fmt.duration(Double(row.counters.cpuNs) / 1e9)
        case .pCoreTime: return Fmt.duration(Double(row.counters.pCpuNs) / 1e9)
        case .energy: return Fmt.power(row.energyMilliwatts)
        case .energyTotal:
            return row.counters.energyNj > 0 ? Fmt.energy(Double(row.counters.energyNj) / 1e9) : "—"
        case .pcore:
            return row.performanceCoreShare > 0
                ? Fmt.percent(row.performanceCoreShare * 100, decimals: 0) : "—"
        case .gpu: return Fmt.percent(row.gpuPercent, decimals: 1)
        case .gpuTime: return Fmt.duration(Double(row.counters.gpuNs) / 1e9)
        case .memory: return row.counters.footprint > 0 ? Fmt.bytes(row.counters.footprint) : "—"
        case .resident: return row.counters.resident > 0 ? Fmt.bytes(row.counters.resident) : "—"
        case .wakeups: return Fmt.count(row.idleWakeupsPerSec)
        case .interruptWakeups: return Fmt.count(row.interruptWakeupsPerSec)
        case .diskIO:
            let r = row.diskReadPerSec, w = row.diskWritePerSec
            if r < 1 && w < 1 { return "—" }
            return "\(Fmt.bytes(r))/\(Fmt.bytes(w))"
        case .diskRead: return Fmt.rate(row.diskReadPerSec)
        case .diskWrite: return Fmt.rate(row.diskWritePerSec)
        case .threads: return row.counters.threads > 0 ? String(row.counters.threads) : "—"
        case .cycles: return Fmt.bigNumber(row.counters.cycles)
        case .instructions: return Fmt.bigNumber(row.counters.instructions)
        }
    }

    static func color(_ row: ProcRow, _ column: ProcColumn) -> Color {
        switch column {
        case .name: return row.readable ? .primary : .secondary
        case .cpu: return row.cpuPercent > 20 ? VitalsTheme.cpu : .primary
        case .energy: return VitalsTheme.energyColor(row.energyMilliwatts)
        case .pcore: return row.performanceCoreShare > 0.75 ? VitalsTheme.warn : .secondary
        case .gpu: return row.gpuPercent > 0 ? VitalsTheme.gpu : .secondary
        case .memory, .resident: return .primary
        case .wakeups, .interruptWakeups:
            let rate = column == .wakeups ? row.idleWakeupsPerSec : row.interruptWakeupsPerSec
            return rate > 20 ? VitalsTheme.wakeups : .secondary
        case .measured: return row.readable ? VitalsTheme.ok : VitalsTheme.warn
        default: return .secondary
        }
    }
}

extension Array where Element == ProcRow {
    /// Whether two snapshots would draw the same table.
    ///
    /// Compared on the fields the table shows rather than with `==`, so that a
    /// counter the table does not display cannot force a reload — and so a reload
    /// never happens mid-scroll for a value nobody can see.
    func identical(to other: [ProcRow]) -> Bool {
        guard count == other.count else { return false }
        for (a, b) in zip(self, other) {
            if a.pid != b.pid || a.cpuPercent != b.cpuPercent
                || a.energyMilliwatts != b.energyMilliwatts
                || a.counters.footprint != b.counters.footprint
                || a.gpuPercent != b.gpuPercent
                || a.counters.threads != b.counters.threads {
                return false
            }
        }
        return true
    }
}
