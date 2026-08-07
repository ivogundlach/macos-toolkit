import SwiftUI
import AppKit

private struct HeaderMenuColumn {
    let column: ProcColumn
    let isVisible: Bool
    let canHide: Bool
}

private final class HeaderMenuAction: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke(_ sender: Any?) { handler() }
}

private extension NSPasteboard.PasteboardType {
    static let vitalsProcessColumn = NSPasteboard.PasteboardType("com.ivogundlach.vitals.process-column")
}

/// Native AppKit header cell. It keeps sorting, column dragging, and the secondary-click
/// NSMenu reliable inside SwiftUI's horizontal ScrollView, like Activity Monitor.
private final class HeaderInteractionNSView: NSView, NSDraggingSource {
    private let label = NSTextField(labelWithString: "")
    private let dropIndicator = CALayer()
    var column: ProcColumn?
    var onPrimaryClick: (() -> Void)?
    var onMove: ((ProcColumn, ProcColumn, Bool) -> Void)?
    var columns: [HeaderMenuColumn] = []
    var onToggle: ((ProcColumn, Bool) -> Void)?
    var canRestore = false
    var onRestore: (() -> Void)?
    private var retainedActions: [HeaderMenuAction] = []
    private var initialMouseDown: NSEvent?
    private var startedDragging = false
    private var dropAfter = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
        wantsLayer = true
        dropIndicator.backgroundColor = NSColor.controlAccentColor.cgColor
        dropIndicator.isHidden = true
        layer?.addSublayer(dropIndicator)
        registerForDraggedTypes([.vitalsProcessColumn])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        // Two AppKit defaults to undo. NSTextFieldCell insets its text ~2pt from
        // the field's bounds, which is enough to knock a right-aligned header off
        // the numeric column it labels. And a label taller than its text draws that
        // text at the *top* of the frame rather than centred, which is what put
        // noticeably more air below the kickers than above them.
        let textHeight = label.fittingSize.height
        label.frame = NSRect(x: bounds.minX - 2,
                             y: bounds.midY - textHeight / 2,
                             width: bounds.width + 4,
                             height: textHeight)
        let x = dropAfter ? bounds.maxX - 2 : bounds.minX
        dropIndicator.frame = NSRect(x: x, y: bounds.minY, width: 2, height: bounds.height)
    }

    /// A kerned uppercase kicker rather than a title on a filled bar. The header
    /// used to be a solid `sidebar` block, which read as a fourth stacked slab in a
    /// view already made of stacked slabs; demoting it to type means the rule under
    /// it is the only thing separating it from the rows.
    func configure(title: String, alignment: Alignment, fontSize: CGFloat,
                   isSorted: Bool, descending: Bool) {
        let text = isSorted ? "\(title.uppercased()) \(descending ? "▾" : "▴")"
                            : title.uppercased()
        // Alignment has to ride *inside* the attributed string. An attributed value
        // set on an NSTextField overrides the field's own `alignment` and
        // `lineBreakMode`, which is why every numeric header was sitting flush left
        // against a right-aligned column of numbers.
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment == .trailing ? .right : .left
        paragraph.lineBreakMode = .byTruncatingTail
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: isSorted ? NSColor.secondaryLabelColor
                                       : NSColor.tertiaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        // Kerning is trailing, so applying it to the last character pushes
        // right-aligned headers off the numeric column they label.
        if text.count > 1 {
            attributed.addAttribute(.kern, value: fontSize * 0.06,
                                    range: NSRange(location: 0, length: text.count - 1))
        }
        label.attributedStringValue = attributed
        label.alignment = alignment == .trailing ? .right : .left
    }

    override func mouseDown(with event: NSEvent) {
        initialMouseDown = event
        startedDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !startedDragging, let initialMouseDown, let column else { return }
        let origin = convert(initialMouseDown.locationInWindow, from: nil)
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - origin.x, current.y - origin.y) >= 4 else { return }

        startedDragging = true
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(column.rawValue, forType: .vitalsProcessColumn)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: dragImage())
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !startedDragging { onPrimaryClick?() }
        initialMouseDown = nil
        startedDragging = false
    }

    private func dragImage() -> NSImage {
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else {
            return NSImage(size: bounds.size)
        }
        cacheDisplay(in: bounds, to: bitmap)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    private func updateDropIndicator(for sender: NSDraggingInfo) -> NSDragOperation {
        guard let target = column,
              let rawValue = sender.draggingPasteboard.string(forType: .vitalsProcessColumn),
              let source = ProcColumn(rawValue: rawValue), source != target else {
            dropIndicator.isHidden = true
            return []
        }
        dropAfter = convert(sender.draggingLocation, from: nil).x >= bounds.midX
        needsLayout = true
        dropIndicator.isHidden = false
        return .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropIndicator(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropIndicator(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropIndicator.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropIndicator.isHidden = true }
        guard let target = column,
              let rawValue = sender.draggingPasteboard.string(forType: .vitalsProcessColumn),
              let source = ProcColumn(rawValue: rawValue), source != target else { return false }
        let after = convert(sender.draggingLocation, from: nil).x >= bounds.midX
        onMove?(source, target, after)
        return true
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        retainedActions.removeAll(keepingCapacity: true)
        for entry in columns {
            let action = HeaderMenuAction { [weak self] in
                self?.onToggle?(entry.column, !entry.isVisible)
            }
            retainedActions.append(action)
            let item = NSMenuItem(title: entry.column.title,
                                  action: #selector(HeaderMenuAction.invoke(_:)),
                                  keyEquivalent: "")
            item.target = action
            item.state = entry.isVisible ? .on : .off
            item.isEnabled = entry.canHide || !entry.isVisible
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let restoreAction = HeaderMenuAction { [weak self] in self?.onRestore?() }
        retainedActions.append(restoreAction)
        let restore = NSMenuItem(title: "Restore Default Columns",
                                 action: #selector(HeaderMenuAction.invoke(_:)),
                                 keyEquivalent: "")
        restore.target = restoreAction
        restore.isEnabled = canRestore
        menu.addItem(restore)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

private struct HeaderInteractionArea: NSViewRepresentable {
    var column: ProcColumn
    var title: String
    var alignment: Alignment
    var fontSize: CGFloat
    var isSorted: Bool
    var descending: Bool
    var onPrimaryClick: () -> Void
    var onMove: (ProcColumn, ProcColumn, Bool) -> Void
    var columns: [HeaderMenuColumn]
    var onToggle: (ProcColumn, Bool) -> Void
    var canRestore: Bool
    var onRestore: () -> Void

    func makeNSView(context: Context) -> HeaderInteractionNSView {
        HeaderInteractionNSView()
    }

    func updateNSView(_ view: HeaderInteractionNSView, context: Context) {
        view.configure(title: title, alignment: alignment, fontSize: fontSize,
                       isSorted: isSorted, descending: descending)
        view.column = column
        view.onPrimaryClick = onPrimaryClick
        view.onMove = onMove
        view.columns = columns
        view.onToggle = onToggle
        view.canRestore = canRestore
        view.onRestore = onRestore
        view.toolTip = "Click to sort; drag to reorder; right-click to choose columns"
    }
}

/// The dense process table. Compact rows and a monospaced numeric grid fit
/// roughly twice as many processes on screen as Activity Monitor, with columns it
/// does not offer at all: real energy in milliwatts, performance-core share,
/// per-process GPU, and idle wakeups.
struct ProcessesView: View {
    @ObservedObject var model: AppModel
    @State private var selected: Int32?
    @State private var confirmKill: ProcRow?
    @State private var inspecting: ProcRow?

    private var selectedRow: ProcRow? {
        guard let selected else { return nil }
        return model.snapshot.processes.first { $0.pid == selected }
    }

    private var processFontSize: CGFloat { CGFloat(model.mainProcessFontSize) }
    private var processRowHeight: CGFloat { max(18, processFontSize + 7) }

    /// Double-click-to-inspect, kept out of SwiftUI's gesture system on purpose:
    /// a `TapGesture(count: 2)` on a row is what made selection take up to a
    /// second to appear. AppKit reports `clickCount` on the event itself, so the
    /// second click can be recognised without the first one having to wait.
    @State private var tableFrame: CGRect = .zero
    @State private var doubleClickMonitor: Any?

    /// Every column's width, in `model.processColumns` order.
    ///
    /// One array, read by the header, the rows and the divider alike. It used to be
    /// two: the header cell is an `NSViewRepresentable` with no intrinsic size so it
    /// filled whatever it was offered, while the row's cell reported the width of
    /// its text, and an `HStack` splits slack in proportion to what each child asks
    /// for — measured at up to 13pt of drift by the fourth column.
    ///
    /// Spare width goes to the right of the last column rather than being shared out
    /// between them. Widening the columns to fill the pane pushes every number
    /// further from the one beside it and from the name it belongs to, which is the
    /// distance the eye actually has to travel; a table that stops short of the
    /// right edge costs nothing to read.
    private var columnWidths: [CGFloat] {
        model.processColumns.map(\.width)
    }

    private var headerRowHeight: CGFloat { max(VitalsTheme.headerHeight, processFontSize + 17) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            table
            Divider()
            statusBar
        }
        // No canvas here. `ContentView` installs one at the window root, and it is
        // the canvas that paints the dark ground — a second one nested inside it
        // repainted that ground on top of the table, which is why the rows sat on
        // black while every other surface in the app sat on the window colour.
        .alert(item: $confirmKill) { row in
            Alert(title: Text("Force quit \(row.name)?"),
                  message: Text("PID \(row.pid) will be sent SIGKILL. Unsaved work is lost."),
                  primaryButton: .destructive(Text("Force Quit")) {
                      _ = model.terminate(pid: row.pid, force: true)
                  },
                  secondaryButton: .cancel())
        }
        .sheet(item: $inspecting) { row in
            ProcessInspectorView(pid: row.pid, model: model,
                                 onQuit: { force in _ = model.terminate(pid: row.pid, force: force) })
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            // Force-quit and inspect the selected process, like Activity Monitor.
            Button {
                if let row = selectedRow { confirmKill = row }
            } label: {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(selectedRow == nil ? Color.secondary.opacity(0.4)
                                                        : VitalsTheme.critical)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(selectedRow == nil)
            .help(selectedRow == nil ? "Select a process to force quit"
                                     : "Force quit \(selectedRow?.name ?? "")")

            Button {
                inspecting = selectedRow
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(selectedRow == nil ? Color.secondary.opacity(0.4)
                                                        : Color.accentColor)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(selectedRow == nil)
            .help(selectedRow == nil ? "Select a process to inspect"
                                     : "Inspect \(selectedRow?.name ?? "")")

            // The four scopes live in a compact native menu instead of a wide
            // segmented control that crowded the toolbar and overlapped the icons.
            Menu {
                Picker("Show", selection: $model.scope) {
                    ForEach(ProcessScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(model.scope.title, systemImage: "line.3.horizontal.decrease.circle")
                    .font(VitalsTheme.label)
            }
            .fixedSize()
            .focusEffectDisabled()
            .help("Filter which processes are listed")

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
                TextField("Filter by name or PID", text: $model.search)
                    .textFieldStyle(.plain)
                    .font(VitalsTheme.label)
                if !model.search.isEmpty {
                    Button { model.search = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: VitalsTheme.controlRadius).fill(VitalsTheme.inset))
            .overlay(RoundedRectangle(cornerRadius: VitalsTheme.controlRadius)
                .stroke(VitalsTheme.border, lineWidth: 1))
            .frame(maxWidth: 260)

            Spacer()
        }
        .padding(.horizontal, VitalsTheme.padL).padding(.vertical, VitalsTheme.padS)
    }

    private func header(widths: [CGFloat]) -> some View {
        HStack(spacing: VitalsTheme.padS) {
            ForEach(Array(model.processColumns.enumerated()), id: \.element) { index, column in
                HeaderInteractionArea(
                    column: column,
                    title: column.title,
                    alignment: column.alignment,
                    fontSize: max(8.5, processFontSize - 2),
                    isSorted: model.sort == column.sort,
                    descending: model.sortDescending,
                    onPrimaryClick: { model.toggleSort(column.sort) },
                    onMove: { model.moveProcessColumn($0, relativeTo: $1, after: $2) },
                    columns: ProcColumn.allCases.map {
                        HeaderMenuColumn(column: $0,
                                         isVisible: model.processColumns.contains($0),
                                         canHide: model.processColumns.count > 1)
                    },
                    onToggle: { model.setProcessColumn($0, visible: $1, after: column) },
                    canRestore: model.processColumns != ProcColumns.defaults,
                    onRestore: { model.restoreDefaultProcessColumns() })
                .frame(width: widths[index], height: headerRowHeight)
            }
            Spacer(minLength: 0)
        }
        // Two steps, and both are load-bearing. `fixedSize` takes the header's ideal
        // width so a column set wider than the pane runs off the right edge the way
        // the rows do, instead of an HStack centring its overflow and sliding every
        // kicker off the numbers it labels. But a fixed-width child of a VStack is
        // then *centred* in the pane, so the outer frame is what actually pins it
        // left. `fixedSize` alone moves the whole header to the middle.
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: headerRowHeight)
        .padding(.leading, VitalsTheme.tableInset)
    }

    private var tableContentWidth: CGFloat {
        let columns = model.processColumns
        return columns.reduce(0) { $0 + $1.width }
            + CGFloat(max(0, columns.count - 1)) * VitalsTheme.padS + VitalsTheme.padM * 2
    }

    /// One continuous hairline between the name field and the numeric grid, drawn
    /// over the pane rather than inside each row. It is what lets the bands stay
    /// as sparse as they are: the vertical rule carries "these are two different
    /// kinds of column", so the horizontal marks only have to carry position.
    @ViewBuilder
    private func columnRule(widths: [CGFloat]) -> some View {
        if let name = model.processColumns.firstIndex(of: .name) {
            Rectangle()
                .fill(VitalsTheme.borderStrong)
                .frame(width: 1)
                .padding(.top, headerRowHeight)
                .offset(x: VitalsTheme.tableInset + widths[name] + VitalsTheme.padS / 2)
                .allowsHitTesting(false)
        }
    }

    private var table: some View {
        GeometryReader { geometry in
            // No horizontal scrolling, ever: the table always fits the window and
            // columns compress instead of running off the side.
            let widths = columnWidths
            VStack(spacing: 0) {
                header(widths: widths)
                Rectangle().fill(VitalsTheme.borderStrong).frame(height: 1)
                // AppKit from here down. See `ProcessTable` for why: SwiftUI rows
                // could not carry twelve columns at scroll speed, and the selection,
                // double-click and context menu are all native here rather than
                // gestures competing with the scroller.
                ProcessTable(rows: model.visibleProcesses,
                             columns: model.processColumns,
                             widths: widths,
                             userName: { model.userName($0) },
                             fontSize: processFontSize,
                             rowHeight: processRowHeight,
                             bandRun: VitalsTheme.rowBandRun,
                             selected: $selected,
                             onInspect: { inspecting = $0 },
                             onQuit: { row, force in
                                 _ = model.terminate(pid: row.pid, force: force)
                             },
                             onConfirmKill: { confirmKill = $0 })
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { tableFrame = $0 }
            // Clip before the glass, or rows square off the pane's rounded corners.
            .clipShape(RoundedRectangle(cornerRadius: VitalsTheme.cardRadius, style: .continuous))
            .overlay(alignment: .topLeading) { columnRule(widths: widths) }
            // The table is one glass surface, not one per row: the material's cost
            // scales with the number of separately blended surfaces, and this view
            // routinely holds 400 of them.
            // No `refractiveGlass` here, and only here. See `VitalsTheme.paneFill`:
            // the material's blur re-renders on every scrolled frame. The shadow
            // hangs off the background shape rather than off the content, because a
            // `.shadow` on the content re-rasterises the whole pane each frame too.
            .background {
                RoundedRectangle(cornerRadius: VitalsTheme.cardRadius, style: .continuous)
                    .fill(VitalsTheme.paneFill)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            }
            .overlay(
                RoundedRectangle(cornerRadius: VitalsTheme.cardRadius, style: .continuous)
                    .stroke(VitalsTheme.border, lineWidth: 1)
            )
        }
        .padding(.horizontal, VitalsTheme.padL)
        .padding(.top, VitalsTheme.padM)
        .padding(.bottom, VitalsTheme.padM)
        .onAppear {
            guard doubleClickMonitor == nil else { return }
            doubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                guard event.clickCount == 2,
                      let height = event.window?.contentView?.bounds.height else { return event }
                // AppKit measures from the bottom-left, SwiftUI's global space from
                // the top-left.
                let point = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
                if tableFrame.contains(point),
                   point.y > tableFrame.minY + headerRowHeight,
                   let row = selectedRow {
                    inspecting = row
                }
                return event
            }
        }
        .onDisappear {
            if let doubleClickMonitor { NSEvent.removeMonitor(doubleClickMonitor) }
            doubleClickMonitor = nil
        }
    }

    @ViewBuilder
    private func menu(for row: ProcRow) -> some View {
        Text("\(row.name) — PID \(row.pid)")
        Divider()
        Button("Get Info") { selected = row.pid; inspecting = row }
        Button("Quit") { _ = model.terminate(pid: row.pid, force: false) }
        Button("Force Quit") { confirmKill = row }
        Divider()
        if !row.counters.path.isEmpty {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.counters.path, forType: .string)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: row.counters.path)])
            }
        }
        Button("Copy PID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(row.pid), forType: .string)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text("\(model.visibleProcesses.count) shown")
                .font(VitalsTheme.labelSmall).foregroundStyle(.secondary)
            Text("\(model.snapshot.totalProcesses) total")
                .font(VitalsTheme.labelSmall).foregroundStyle(.secondary)
            if model.snapshot.unreadableProcesses > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "lock.fill").font(.system(size: 8))
                    Text("\(model.snapshot.unreadableProcesses) need helper")
                }
                .font(VitalsTheme.labelSmall)
                .foregroundStyle(VitalsTheme.warn)
                .help("These processes run as another user. Their CPU, energy and disk "
                      + "counters are unreadable without the privileged helper.")
            }
            Spacer()
            Text("every \(Fmt.duration(model.interval))")
                .font(VitalsTheme.labelSmall).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, VitalsTheme.padL).padding(.vertical, VitalsTheme.padS)
    }
}
