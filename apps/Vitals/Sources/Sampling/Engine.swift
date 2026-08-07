import Foundation

/// Measured power, in watts, split by how it was obtained.
///
/// Deliberately avoids inventing numbers. On Apple Silicon the per-rail CPU/ANE/DRAM
/// energy counters are root-only: a survey of all 9,528 IOReport channels found
/// `GPU Energy` to be the only energy channel that moves unprivileged. So CPU power
/// here is *attributed* power — the sum of real per-process `ri_energy_nj` deltas —
/// which tracks load closely (measured 0.3 W idle, 7.4 W across four busy P-cores).
struct PowerBreakdown {
    /// Sum of per-process energy for processes this build can actually read.
    var attributedCPUWatts: Double = 0
    /// Performance-core share of the attributed figure.
    var attributedPerformanceWatts: Double = 0
    /// GPU rail, straight from IOReport. Genuinely measured.
    var gpuWatts: Double = 0
    /// Exact CPU/ANE/DRAM rails, only populated when the privileged helper runs
    /// powermetrics. Zero means "not measured", never "no power drawn".
    var cpuRailWatts: Double = 0
    var aneWatts: Double = 0
    var dramWatts: Double = 0
    var hasRailData = false

    /// Whole-machine draw including display and peripherals, from battery telemetry.
    var systemWatts: Double = 0

    /// Processes whose energy could not be read, so their draw is missing from
    /// `attributedCPUWatts`.
    var unreadableProcesses = 0

    /// Best CPU figure available: exact rails when the helper supplies them,
    /// otherwise the attributed sum.
    var cpuWatts: Double { hasRailData ? cpuRailWatts : attributedCPUWatts }

    /// Everything measured on the SoC.
    var accountedWatts: Double { cpuWatts + gpuWatts + aneWatts + dramWatts }

    /// Display backlight, radios, peripherals — plus any process we could not read.
    /// Shown as "unaccounted" rather than pretending it is a known component.
    var unaccountedWatts: Double { max(0, systemWatts - accountedWatts) }
}

/// One complete observation of the machine.
struct Snapshot {
    var at = Date()
    var interval: TimeInterval = 0
    var processes: [ProcRow] = []
    var system = SystemProbe.Stats()
    var gpu = GPUProbe.DeviceStats()
    var battery = BatteryProbe.Stats()
    var power = PowerBreakdown()
    var totalProcesses = 0
    var unreadableProcesses = 0

    /// Processes ranked by the metric that actually predicts battery drain.
    func topEnergy(_ n: Int) -> [ProcRow] {
        processes.filter { $0.energyMilliwatts > 0 }
            .sorted { $0.energyMilliwatts > $1.energyMilliwatts }
            .prefix(n).map { $0 }
    }

    /// Idle wakeups keep the SoC out of its low-power states even at negligible CPU.
    func topWakeups(_ n: Int) -> [ProcRow] {
        processes.filter { $0.idleWakeupsPerSec > 0 }
            .sorted { $0.idleWakeupsPerSec > $1.idleWakeupsPerSec }
            .prefix(n).map { $0 }
    }

    func topGPU(_ n: Int) -> [ProcRow] {
        processes.filter { $0.gpuPercent > 0 }
            .sorted { $0.gpuPercent > $1.gpuPercent }
            .prefix(n).map { $0 }
    }

    func topCPU(_ n: Int) -> [ProcRow] {
        processes.filter { $0.cpuPercent > 0 }
            .sorted { $0.cpuPercent > $1.cpuPercent }
            .prefix(n).map { $0 }
    }

    /// Footprint is readable for every process, unlike the rusage counters, so this
    /// does not filter on `readable`.
    func topMemory(_ n: Int) -> [ProcRow] {
        processes.filter { $0.counters.footprint > 0 }
            .sorted { $0.counters.footprint > $1.counters.footprint }
            .prefix(n).map { $0 }
    }
}

/// Drives every probe on one cadence and produces snapshots.
final class VitalsEngine {
    private let processes = ProcessSampler()
    private let system = SystemProbe()
    private let ioReport = IOReport()
    private var energyChannel: IOReport.Channel?

    let hasIOReport: Bool

    init() {
        energyChannel = ioReport?.subscribe(group: "Energy Model")
        hasIOReport = energyChannel != nil
    }

    /// The first snapshot has no predecessor, so all rates read zero. Callers that
    /// need live numbers immediately should discard it and sample again.
    func sampleOnce() -> Snapshot {
        var snap = Snapshot()
        let result = processes.sample()
        snap.processes = result.rows
        snap.interval = result.interval
        snap.totalProcesses = result.totalProcesses
        snap.unreadableProcesses = result.unreadableProcesses
        snap.system = system.sample()
        snap.gpu = GPUProbe.sampleDevice()
        snap.battery = BatteryProbe.sample()
        snap.power = samplePower(snapshot: snap)
        return snap
    }

    func userName(_ uid: uid_t) -> String { processes.userName(uid) }

    /// Supply counters gathered by the privileged helper for processes this uid
    /// cannot read. Empty dictionary disables the augmentation.
    func setPrivilegedCounters(_ counters: [Int32: ProcCounters]) {
        processes.privilegedCounters = counters
    }

    private func samplePower(snapshot: Snapshot) -> PowerBreakdown {
        var p = PowerBreakdown()
        p.systemWatts = snapshot.battery.systemLoadWatts
        p.unreadableProcesses = snapshot.unreadableProcesses

        // Real per-process energy, summed. Covers only processes we can read.
        var total = 0.0, performance = 0.0
        for row in snapshot.processes where row.readable {
            total += row.energyMilliwatts
            performance += row.energyMilliwatts * row.performanceCoreShare
        }
        p.attributedCPUWatts = total / 1000.0
        p.attributedPerformanceWatts = performance / 1000.0

        // Rail data. On stock hardware only the GPU channel moves unprivileged;
        // the CPU/ANE/DRAM branches light up when a helper widens access.
        guard let channel = energyChannel else { return p }
        let (readings, interval) = channel.poll()
        guard interval > 0 else { return p }

        for r in readings {
            guard let joules = r.joules, joules > 0 else { continue }
            let watts = joules / interval
            let name = r.name.uppercased()
            if name.contains("GPU") {
                p.gpuWatts += watts
            } else if name.contains("ANE") {
                p.aneWatts += watts
            } else if name.contains("DRAM") || name.contains("SDRAM") {
                p.dramWatts += watts
            } else if name.hasPrefix("ECPU") || name.hasPrefix("EACC")
                        || name.hasPrefix("PCPU") || name.hasPrefix("PACC") {
                p.cpuRailWatts += watts
                p.hasRailData = true
            }
        }
        return p
    }
}
