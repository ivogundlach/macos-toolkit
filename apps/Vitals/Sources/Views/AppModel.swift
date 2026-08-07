import SwiftUI
import Combine

/// Which metrics the menu bar shows, in order. Everything is user-configurable.
enum MenuBarMetric: String, CaseIterable, Identifiable, Codable {
    case cpu, gpu, memory, energy, systemPower, battery, network, disk, wakeups

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "Memory"
        case .energy: return "Top process power"
        case .systemPower: return "System watts"
        case .battery: return "Battery"
        case .network: return "Network"
        case .disk: return "Disk"
        case .wakeups: return "Idle wakeups"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "cube.transparent"
        case .memory: return "memorychip"
        case .energy: return "bolt.fill"
        case .systemPower: return "bolt.circle"
        case .battery: return "battery.75"
        case .network: return "network"
        case .disk: return "internaldrive"
        case .wakeups: return "waveform.path.ecg"
        }
    }

    /// Menu bar prefix. SF Symbols are dropped from a MenuBarExtra label, so when
    /// several metrics are shown these short words are what disambiguates them.
    var shortLabel: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "MEM"
        case .energy: return "TOP"
        case .systemPower: return "PWR"
        case .battery: return "BAT"
        case .network: return "NET"
        case .disk: return "DSK"
        case .wakeups: return "WAK"
        }
    }

    var tint: Color {
        switch self {
        case .cpu: return VitalsTheme.cpu
        case .gpu: return VitalsTheme.gpu
        case .memory: return VitalsTheme.memory
        case .energy, .systemPower: return VitalsTheme.energy
        case .battery: return VitalsTheme.battery
        case .network: return VitalsTheme.network
        case .disk: return VitalsTheme.disk
        case .wakeups: return VitalsTheme.wakeups
        }
    }

    /// The compact string shown in the menu bar itself.
    func render(_ s: Snapshot) -> String {
        switch self {
        case .cpu: return String(format: "%.0f%%", s.system.cpuUsage * 100)
        case .gpu: return String(format: "%.0f%%", s.gpu.deviceUtilization)
        case .memory:
            // Used memory in GB (base-2, matching the System tab), not a percentage.
            return String(format: "%.1f GB", Double(s.system.memory.used) / 1_073_741_824)
        case .energy:
            return Fmt.power(s.topEnergy(1).first?.energyMilliwatts ?? 0)
        case .systemPower:
            return s.power.systemWatts > 0 ? String(format: "%.1fW", s.power.systemWatts) : "—"
        case .battery:
            return s.battery.present ? String(format: "%.0f%%", s.battery.percent) : "—"
        case .network:
            return "↓\(Fmt.bytes(s.system.io.inBytesPerSec))"
        case .disk:
            return "↧\(Fmt.bytes(s.system.io.readBytesPerSec))"
        case .wakeups:
            return String(format: "%.0f", s.processes.reduce(0) { $0 + $1.idleWakeupsPerSec })
        }
    }
}

/// How the process list is sorted.
enum ProcessSort: String, CaseIterable, Identifiable, Codable {
    case pid, ppid, name, user, uid, path, measured, status, started
    case cpu, cpuTime, pCoreTime, energy, energyTotal, performanceCoreShare
    case gpu, gpuTime, memory, resident, wakeups, interruptWakeups
    case diskIO, diskRead, diskWrite, threads, cycles, instructions
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pid: return "PID"
        case .ppid: return "PPID"
        case .name: return "Name"
        case .user: return "User"
        case .uid: return "UID"
        case .path: return "Path"
        case .measured: return "Measured"
        case .status: return "Status"
        case .started: return "Started"
        case .cpu: return "CPU"
        case .cpuTime: return "CPU time"
        case .pCoreTime: return "P-core time"
        case .energy: return "Energy"
        case .energyTotal: return "Energy total"
        case .performanceCoreShare: return "P-core share"
        case .gpu: return "GPU"
        case .gpuTime: return "GPU time"
        case .memory: return "Memory"
        case .resident: return "Resident memory"
        case .wakeups: return "Wakeups"
        case .interruptWakeups: return "Interrupt wakeups"
        case .diskIO: return "Disk"
        case .diskRead: return "Disk read"
        case .diskWrite: return "Disk write"
        case .threads: return "Threads"
        case .cycles: return "Cycles"
        case .instructions: return "Instructions"
        }
    }
}

enum ProcessScope: String, CaseIterable, Identifiable, Codable {
    case all, mine, active, unreadable
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All Processes"
        case .mine: return "My Processes"
        case .active: return "Active Only"
        case .unreadable: return "Needs Helper"
        }
    }
}

/// Ranked process lists available in the menu bar dropdown.
enum PanelProcessMetric: String, CaseIterable, Identifiable, Codable {
    case energy, cpu, gpu, memory, wakeups, diskIO, threads

    var id: String { rawValue }

    var title: String {
        switch self {
        case .energy: return "Top energy processes"
        case .cpu: return "Top CPU processes"
        case .gpu: return "Top GPU processes"
        case .memory: return "Top memory processes"
        case .wakeups: return "Top wakeup processes"
        case .diskIO: return "Top disk processes"
        case .threads: return "Top thread-count processes"
        }
    }

    var panelTitle: String {
        switch self {
        case .energy: return "Top energy"
        case .cpu: return "Top CPU"
        case .gpu: return "Top GPU"
        case .memory: return "Top memory"
        case .wakeups: return "Top wakeups"
        case .diskIO: return "Top disk"
        case .threads: return "Top threads"
        }
    }

    func rows(in snapshot: Snapshot, limit: Int) -> [ProcRow] {
        snapshot.processes.filter { value(for: $0) > 0 }
            .sorted { value(for: $0) > value(for: $1) }
            .prefix(limit).map { $0 }
    }

    func formattedValue(for row: ProcRow) -> String {
        switch self {
        case .energy: return Fmt.power(row.energyMilliwatts)
        case .cpu: return Fmt.percent(row.cpuPercent)
        case .gpu: return Fmt.percent(row.gpuPercent)
        case .memory: return Fmt.bytes(row.counters.footprint)
        case .wakeups: return Fmt.count(row.idleWakeupsPerSec) + "/s"
        case .diskIO: return Fmt.rate(row.diskReadPerSec + row.diskWritePerSec)
        case .threads: return String(row.counters.threads)
        }
    }

    private func value(for row: ProcRow) -> Double {
        switch self {
        case .energy: return row.energyMilliwatts
        case .cpu: return row.cpuPercent
        case .gpu: return row.gpuPercent
        case .memory: return Double(row.counters.footprint)
        case .wakeups: return row.idleWakeupsPerSec
        case .diskIO: return row.diskReadPerSec + row.diskWritePerSec
        case .threads: return Double(row.counters.threads)
        }
    }
}

/// How many rows each dropdown process list shows.
enum PanelListSize: String, CaseIterable, Identifiable, Codable {
    case five, ten, twenty, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .five: return "5"
        case .ten: return "10"
        case .twenty: return "20"
        case .all: return "All"
        }
    }
    /// Row cap; `.all` means every qualifying process.
    var count: Int {
        switch self {
        case .five: return 5
        case .ten: return 10
        case .twenty: return 20
        case .all: return Int.max
        }
    }
    /// `.all` scrolls inside a bounded area; fixed sizes reserve exact height.
    var scrolls: Bool { self == .all }
}

/// Owns sampling and publishes state to the UI.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var isPrimed = false
    /// False while the main window is hidden. The window's content collapses to an
    /// empty view then, so SwiftUI stops laying out the (expensive) process table
    /// off-screen every refresh — that idle layout was the menu-bar-open lag.
    @Published var windowVisible = true

    // Process table state
    @Published var sort: ProcessSort = .energy { didSet { recomputeDisplayed() } }
    @Published var sortDescending = true { didSet { recomputeDisplayed() } }
    @Published var scope: ProcessScope = .all { didSet { recomputeDisplayed() } }
    @Published var search = "" { didSet { recomputeDisplayed() } }

    /// The sorted/filtered rows the table shows. Memoized so it is recomputed only
    /// when the data or the sort/filter changes — not on every view re-evaluation,
    /// which happens on every click and would re-sort ~640 rows needlessly.
    @Published private(set) var displayedProcesses: [ProcRow] = []

    // Settings
    @Published var interval: Double {
        didSet {
            UserDefaults.standard.set(interval, forKey: "interval")
            restartTimer()
        }
    }
    @Published var menuBarMetrics: [MenuBarMetric] {
        didSet { persist(menuBarMetrics, key: "menuBarMetrics") }
    }
    /// Which quick-stat tiles the dropdown panel shows, in order. Separate from the
    /// strip so the panel can stay rich while the strip stays notch-narrow.
    @Published var panelMetrics: [MenuBarMetric] {
        didSet { persist(panelMetrics, key: "panelMetrics") }
    }
    @Published var showMenuBarLabels: Bool {
        didSet { UserDefaults.standard.set(showMenuBarLabels, forKey: "showMenuBarLabels") }
    }
    /// Which ranked process lists the dropdown panel shows, in display order.
    @Published var panelProcessMetrics: [PanelProcessMetric] {
        didSet { persist(panelProcessMetrics, key: "panelProcessMetrics") }
    }
    @Published var panelListSize: PanelListSize {
        didSet { UserDefaults.standard.set(panelListSize.rawValue, forKey: "panelListSize") }
    }
    @Published var panelProcessFontSize: Double {
        didSet { UserDefaults.standard.set(panelProcessFontSize, forKey: "panelProcessFontSize") }
    }
    @Published var mainProcessFontSize: Double {
        didSet { UserDefaults.standard.set(mainProcessFontSize, forKey: "mainProcessFontSize") }
    }
    @Published var processColumns: [ProcColumn] {
        didSet { persist(processColumns, key: "processColumns") }
    }
    @Published var retentionDays: Int {
        didSet { UserDefaults.standard.set(retentionDays, forKey: "retentionDays") }
    }
    /// Shared by every retrospective tab, so switching between them keeps the same
    /// span in view instead of snapping back to a default.
    @Published var historyWindow: HistoryWindow {
        didSet { UserDefaults.standard.set(historyWindow.rawValue, forKey: "historyWindow") }
    }

    private let engine = VitalsEngine()
    private let store = HistoryStore()
    private var timer: Timer?
    private let sampleQueue = DispatchQueue(label: "com.ivogundlach.vitals.sample", qos: .utility)
    private var lastPersist = Date.distantPast

    var hasIOReport: Bool { engine.hasIOReport }
    var historyStore: HistoryStore? { store }

    init() {
        let d = UserDefaults.standard
        interval = d.object(forKey: "interval") as? Double ?? 2.0
        showMenuBarLabels = d.object(forKey: "showMenuBarLabels") as? Bool ?? true
        panelListSize = PanelListSize(rawValue: d.string(forKey: "panelListSize") ?? "") ?? .five
        panelProcessFontSize = min(20, max(10,
            d.object(forKey: "panelProcessFontSize") as? Double ?? 13))
        mainProcessFontSize = min(20, max(10,
            d.object(forKey: "mainProcessFontSize") as? Double ?? 11))
        // Decoded as raw strings, not as `[ProcColumn]`. Decoding straight to the
        // enum throws on a single unrecognised name and takes the whole array with
        // it, so retiring one column would silently reset every other choice the
        // layout had. An unknown name is dropped and the rest is kept.
        if let raw = d.data(forKey: "processColumns"),
           let names = try? JSONDecoder().decode([String].self, from: raw) {
            let decoded = names.compactMap(ProcColumn.init(rawValue:))
            var seen = Set<ProcColumn>()
            let unique = decoded.filter { seen.insert($0).inserted }
            let migrated = unique.isEmpty ? ProcColumns.defaults : ProcColumns.migrated(unique)
            processColumns = migrated
            // `didSet` does not run for an assignment inside `init`, so a migration
            // that only happens once has to write itself back by hand — otherwise it
            // burns its one chance in memory and the saved layout never changes.
            if migrated != unique || decoded.count != names.count {
                Self.persist(migrated, key: "processColumns")
            }
        } else {
            processColumns = ProcColumns.defaults
        }
        // 30 days by default so the Month view on every resource tab has something
        // behind it; the old 14-day default silently truncated it.
        retentionDays = d.object(forKey: "retentionDays") as? Int ?? 30
        historyWindow = HistoryWindow(rawValue: d.string(forKey: "historyWindow") ?? "") ?? .day
        if let raw = d.data(forKey: "menuBarMetrics"),
           let decoded = try? JSONDecoder().decode([MenuBarMetric].self, from: raw) {
            menuBarMetrics = decoded
        } else {
            // Two metrics by default: a notched Mac with a busy menu bar hides
            // items that grow too wide. CPU plus system watts covers both the
            // general-monitor and battery-drain purposes; more can be added in Settings.
            menuBarMetrics = [.cpu, .systemPower]
        }
        if let raw = d.data(forKey: "panelMetrics"),
           let decoded = try? JSONDecoder().decode([MenuBarMetric].self, from: raw) {
            panelMetrics = decoded
        } else {
            panelMetrics = [.cpu, .gpu, .memory, .systemPower]
        }
        if let raw = d.data(forKey: "panelProcessMetrics"),
           let decoded = try? JSONDecoder().decode([PanelProcessMetric].self, from: raw) {
            panelProcessMetrics = decoded
        } else {
            // Preserve the two original switches when migrating existing settings.
            panelProcessMetrics = []
            if d.object(forKey: "panelShowTopEnergy") as? Bool ?? true {
                panelProcessMetrics.append(.energy)
            }
            if d.object(forKey: "panelShowTopGPU") as? Bool ?? true {
                panelProcessMetrics.append(.gpu)
            }
        }
        start()
        store?.prune(retaining: retentionDays)
    }

    func start() {
        restartTimer()
        sample()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    private func sample() {
        sampleQueue.async { [weak self] in
            guard let self else { return }
            // Fold in helper-published counters when the helper is running, so the
            // processes this uid cannot read stop showing as blanks.
            if HelperManager.status() == .installed {
                self.engine.setPrivilegedCounters(HelperManager.readCounters())
            } else {
                self.engine.setPrivilegedCounters([:])
            }
            let snap = self.engine.sampleOnce()
            Task { @MainActor in self.apply(snap) }
        }
    }

    private func apply(_ snap: Snapshot) {
        // The very first snapshot has no predecessor, so every rate is zero.
        // Publishing it would flash an empty table.
        guard isPrimed else { isPrimed = true; snapshot = snap; recomputeDisplayed(); return }
        snapshot = snap
        recomputeDisplayed()

        // Persist at most every 30s regardless of the live refresh rate.
        if Date().timeIntervalSince(lastPersist) >= 30 {
            lastPersist = Date()
            store?.record(snap)
        }
    }

    func userName(_ uid: uid_t) -> String { engine.userName(uid) }

    /// Rows after scope, search and sort are applied (memoized in displayedProcesses).
    var visibleProcesses: [ProcRow] { displayedProcesses }

    private func recomputeDisplayed() {
        var rows = snapshot.processes
        let me = getuid()
        switch scope {
        case .all: break
        case .mine: rows = rows.filter { $0.counters.uid == me }
        case .active: rows = rows.filter { $0.cpuPercent > 0.1 || $0.energyMilliwatts > 1 || $0.gpuPercent > 0 }
        case .unreadable: rows = rows.filter { !$0.readable }
        }
        if !search.isEmpty {
            let q = search.lowercased()
            rows = rows.filter { $0.name.lowercased().contains(q) || String($0.pid).contains(q) }
        }
        rows.sort { a, b in
            let ascending: Bool
            switch sort {
            case .pid: ascending = a.pid < b.pid
            case .ppid: ascending = a.counters.ppid < b.counters.ppid
            case .name: ascending = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .user:
                ascending = userName(a.counters.uid).localizedCaseInsensitiveCompare(
                    userName(b.counters.uid)) == .orderedAscending
            case .uid: ascending = a.counters.uid < b.counters.uid
            case .path:
                ascending = a.counters.path.localizedCaseInsensitiveCompare(b.counters.path) == .orderedAscending
            case .measured: ascending = !a.readable && b.readable
            case .status: ascending = a.counters.status < b.counters.status
            case .started: ascending = a.counters.startAbs < b.counters.startAbs
            case .cpu: ascending = a.cpuPercent < b.cpuPercent
            case .cpuTime: ascending = a.counters.cpuNs < b.counters.cpuNs
            case .pCoreTime: ascending = a.counters.pCpuNs < b.counters.pCpuNs
            case .energy: ascending = a.energyMilliwatts < b.energyMilliwatts
            case .energyTotal: ascending = a.counters.energyNj < b.counters.energyNj
            case .performanceCoreShare: ascending = a.performanceCoreShare < b.performanceCoreShare
            case .gpu: ascending = a.gpuPercent < b.gpuPercent
            case .gpuTime: ascending = a.counters.gpuNs < b.counters.gpuNs
            case .memory: ascending = a.counters.footprint < b.counters.footprint
            case .resident: ascending = a.counters.resident < b.counters.resident
            case .wakeups: ascending = a.idleWakeupsPerSec < b.idleWakeupsPerSec
            case .interruptWakeups: ascending = a.interruptWakeupsPerSec < b.interruptWakeupsPerSec
            case .diskIO:
                ascending = (a.diskReadPerSec + a.diskWritePerSec)
                    < (b.diskReadPerSec + b.diskWritePerSec)
            case .diskRead: ascending = a.diskReadPerSec < b.diskReadPerSec
            case .diskWrite: ascending = a.diskWritePerSec < b.diskWritePerSec
            case .threads: ascending = a.counters.threads < b.counters.threads
            case .cycles: ascending = a.counters.cycles < b.counters.cycles
            case .instructions: ascending = a.counters.instructions < b.counters.instructions
            }
            if ascending { return !sortDescending }
            // Resolve equality/reverse order without violating sort's strict ordering.
            let reverseAscending: Bool
            switch sort {
            case .name: reverseAscending = b.name.localizedCaseInsensitiveCompare(a.name) == .orderedAscending
            case .user:
                reverseAscending = userName(b.counters.uid).localizedCaseInsensitiveCompare(
                    userName(a.counters.uid)) == .orderedAscending
            case .path:
                reverseAscending = b.counters.path.localizedCaseInsensitiveCompare(a.counters.path) == .orderedAscending
            default: reverseAscending = false
            }
            return sortDescending && (reverseAscending || !valuesEqual(a, b, for: sort))
        }
        displayedProcesses = rows
    }

    private func valuesEqual(_ a: ProcRow, _ b: ProcRow, for sort: ProcessSort) -> Bool {
        switch sort {
        case .pid: return a.pid == b.pid
        case .ppid: return a.counters.ppid == b.counters.ppid
        case .name: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedSame
        case .user: return userName(a.counters.uid) == userName(b.counters.uid)
        case .uid: return a.counters.uid == b.counters.uid
        case .path: return a.counters.path.localizedCaseInsensitiveCompare(b.counters.path) == .orderedSame
        case .measured: return a.readable == b.readable
        case .status: return a.counters.status == b.counters.status
        case .started: return a.counters.startAbs == b.counters.startAbs
        case .cpu: return a.cpuPercent == b.cpuPercent
        case .cpuTime: return a.counters.cpuNs == b.counters.cpuNs
        case .pCoreTime: return a.counters.pCpuNs == b.counters.pCpuNs
        case .energy: return a.energyMilliwatts == b.energyMilliwatts
        case .energyTotal: return a.counters.energyNj == b.counters.energyNj
        case .performanceCoreShare: return a.performanceCoreShare == b.performanceCoreShare
        case .gpu: return a.gpuPercent == b.gpuPercent
        case .gpuTime: return a.counters.gpuNs == b.counters.gpuNs
        case .memory: return a.counters.footprint == b.counters.footprint
        case .resident: return a.counters.resident == b.counters.resident
        case .wakeups: return a.idleWakeupsPerSec == b.idleWakeupsPerSec
        case .interruptWakeups: return a.interruptWakeupsPerSec == b.interruptWakeupsPerSec
        case .diskIO:
            return a.diskReadPerSec + a.diskWritePerSec == b.diskReadPerSec + b.diskWritePerSec
        case .diskRead: return a.diskReadPerSec == b.diskReadPerSec
        case .diskWrite: return a.diskWritePerSec == b.diskWritePerSec
        case .threads: return a.counters.threads == b.counters.threads
        case .cycles: return a.counters.cycles == b.counters.cycles
        case .instructions: return a.counters.instructions == b.counters.instructions
        }
    }

    func toggleSort(_ newSort: ProcessSort) {
        if sort == newSort { sortDescending.toggle() } else { sort = newSort; sortDescending = true }
    }

    func setProcessColumn(_ column: ProcColumn, visible: Bool, after anchor: ProcColumn) {
        if visible {
            guard !processColumns.contains(column),
                  let anchorIndex = processColumns.firstIndex(of: anchor) else { return }
            processColumns.insert(column, at: anchorIndex + 1)
        } else {
            guard processColumns.count > 1 else { return }
            processColumns.removeAll { $0 == column }
            if column.sort == sort { sort = processColumns[0].sort }
        }
    }

    func restoreDefaultProcessColumns() {
        processColumns = ProcColumns.defaults
    }

    func moveProcessColumn(_ column: ProcColumn, relativeTo target: ProcColumn, after: Bool) {
        guard column != target, processColumns.contains(column), processColumns.contains(target) else { return }
        var reordered = processColumns
        reordered.removeAll { $0 == column }
        guard let targetIndex = reordered.firstIndex(of: target) else { return }
        reordered.insert(column, at: targetIndex + (after ? 1 : 0))
        processColumns = reordered
    }

    /// Ask the kernel to terminate a process. Signals only; no privilege escalation.
    func terminate(pid: Int32, force: Bool) -> Bool {
        kill(pid, force ? SIGKILL : SIGTERM) == 0
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        Self.persist(value, key: key)
    }

    /// Static so `init` can call it. An instance method is off limits until every
    /// stored property is initialized, which is exactly when the column migration
    /// needs to write its result back.
    private static func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
