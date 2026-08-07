import Foundation
import Darwin

/// Raw cumulative counters for one process at one instant.
///
/// Everything except identity comes from `proc_pid_rusage(RUSAGE_INFO_V6)`, which
/// exposes real per-process energy in nanojoules — not Activity Monitor's unitless
/// "Energy Impact" score. The kernel denies these counters for processes outside the
/// caller's uid, so `readable` records whether the numbers are trustworthy.
struct ProcCounters {
    var pid: Int32 = 0
    var ppid: Int32 = 0
    var uid: uid_t = 0
    var name: String = ""
    var path: String = ""
    var startAbs: UInt64 = 0        // identity: guards against pid reuse
    var status: Int32 = 0
    var readable: Bool = false

    var cpuNs: UInt64 = 0           // user + system
    var pCpuNs: UInt64 = 0          // time on performance cores
    var energyNj: UInt64 = 0
    var pEnergyNj: UInt64 = 0       // performance-core share of that energy
    var cycles: UInt64 = 0
    var instructions: UInt64 = 0
    var idleWakeups: UInt64 = 0     // package idle wakeups: the classic drain culprit
    var interruptWakeups: UInt64 = 0
    var diskRead: UInt64 = 0
    var diskWrite: UInt64 = 0
    var footprint: UInt64 = 0
    var resident: UInt64 = 0
    var gpuNs: UInt64 = 0
    var threads: Int32 = 0

    /// Stable across pid reuse.
    var key: UInt64 { UInt64(bitPattern: Int64(pid)) &* 31 &+ startAbs }
}

/// A process with per-interval rates derived from two consecutive snapshots.
struct ProcRow: Identifiable {
    var id: Int32 { counters.pid }
    var counters: ProcCounters

    var cpuPercent: Double = 0
    var gpuPercent: Double = 0
    var energyMilliwatts: Double = 0
    var idleWakeupsPerSec: Double = 0
    var interruptWakeupsPerSec: Double = 0
    var diskReadPerSec: Double = 0
    var diskWritePerSec: Double = 0

    /// Share of this process's energy spent on performance cores (0...1).
    /// High values on a background process are a strong drain signal: it is being
    /// scheduled on the expensive cores instead of the efficiency cores.
    var performanceCoreShare: Double = 0

    var pid: Int32 { counters.pid }
    var name: String { counters.name }
    var readable: Bool { counters.readable }
}

/// Enumerates processes and turns consecutive raw samples into rates.
final class ProcessSampler {
    private var previous: [UInt64: ProcCounters] = [:]
    private var previousGPU: [Int32: UInt64] = [:]
    private var previousAt = Date()

    /// name/path are stable for a process's lifetime, so resolve them once.
    private var identityCache: [UInt64: (name: String, path: String)] = [:]
    private var userNameCache: [uid_t: String] = [:]

    /// Set when a privileged helper is supplying counters for processes the
    /// current uid cannot read itself.
    var privilegedCounters: [Int32: ProcCounters] = [:]

    struct Result {
        var rows: [ProcRow]
        var interval: TimeInterval
        var totalProcesses: Int
        var unreadableProcesses: Int
    }

    func sample() -> Result {
        let now = Date()
        let interval = max(0.001, now.timeIntervalSince(previousAt))
        let gpuNow = GPUProbe.sampleProcesses()

        var current: [UInt64: ProcCounters] = [:]
        var rows: [ProcRow] = []
        var unreadable = 0

        let kinfos = allProcesses()
        rows.reserveCapacity(kinfos.count)
        current.reserveCapacity(kinfos.count)

        for kp in kinfos {
            let pid = kp.kp_proc.p_pid
            guard pid > 0 else { continue }

            var c = ProcCounters()
            c.pid = pid
            c.ppid = kp.kp_eproc.e_ppid
            c.uid = kp.kp_eproc.e_ucred.cr_uid
            c.status = Int32(kp.kp_proc.p_stat)
            c.startAbs = UInt64(kp.kp_proc.p_starttime.tv_sec) &* 1_000_000
                &+ UInt64(kp.kp_proc.p_starttime.tv_usec)
            c.name = comm(kp)

            let key = c.key
            if let cached = identityCache[key] {
                c.name = cached.name
                c.path = cached.path
            } else {
                c.path = executablePath(pid)
                if let last = c.path.split(separator: "/").last, !last.isEmpty {
                    c.name = String(last)          // full name; p_comm truncates at 16 chars
                }
                identityCache[key] = (c.name, c.path)
            }

            if fillRUsage(pid: pid, into: &c) {
                c.readable = true
            } else if let supplied = privilegedCounters[pid] {
                c = merge(identity: c, counters: supplied)
                c.readable = true
            } else {
                unreadable += 1
            }
            c.threads = threadCount(pid)
            c.gpuNs = gpuNow[pid] ?? 0

            current[key] = c

            var row = ProcRow(counters: c)
            if let prev = previous[key], c.readable, prev.readable {
                row.cpuPercent = rate(c.cpuNs, prev.cpuNs, interval) / 1e9 * 100
                row.energyMilliwatts = rate(c.energyNj, prev.energyNj, interval) / 1e6
                row.idleWakeupsPerSec = rate(c.idleWakeups, prev.idleWakeups, interval)
                row.interruptWakeupsPerSec = rate(c.interruptWakeups, prev.interruptWakeups, interval)
                row.diskReadPerSec = rate(c.diskRead, prev.diskRead, interval)
                row.diskWritePerSec = rate(c.diskWrite, prev.diskWrite, interval)

                let dEnergy = c.energyNj &- min(c.energyNj, prev.energyNj)
                let dPEnergy = c.pEnergyNj &- min(c.pEnergyNj, prev.pEnergyNj)
                row.performanceCoreShare = dEnergy > 0 ? min(1, Double(dPEnergy) / Double(dEnergy)) : 0
            }
            if let prevGPU = previousGPU[pid], c.gpuNs >= prevGPU {
                row.gpuPercent = Double(c.gpuNs - prevGPU) / 1e9 / interval * 100
            }
            rows.append(row)
        }

        previous = current
        previousGPU = gpuNow
        previousAt = now
        // Drop identity entries for processes that have exited.
        if identityCache.count > current.count * 2 {
            identityCache = identityCache.filter { current[$0.key] != nil }
        }

        return Result(rows: rows, interval: interval,
                      totalProcesses: rows.count, unreadableProcesses: unreadable)
    }

    func userName(_ uid: uid_t) -> String {
        if let cached = userNameCache[uid] { return cached }
        var name = String(uid)
        if let pw = getpwuid(uid), let cName = pw.pointee.pw_name {
            name = String(cString: cName)
        }
        userNameCache[uid] = name
        return name
    }

    // MARK: - Kernel access

    private func allProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // The table can grow between sizing and reading; ask for extra headroom.
        size += MemoryLayout<kinfo_proc>.stride * 32
        var buf = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        return Array(buf.prefix(size / MemoryLayout<kinfo_proc>.stride))
    }

    private func fillRUsage(pid: Int32, into c: inout ProcCounters) -> Bool {
        var ri = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard rc == 0 else { return false }
        c.cpuNs = ri.ri_user_time &+ ri.ri_system_time
        c.pCpuNs = ri.ri_user_ptime &+ ri.ri_system_ptime
        c.energyNj = ri.ri_energy_nj
        c.pEnergyNj = ri.ri_penergy_nj
        c.cycles = ri.ri_cycles
        c.instructions = ri.ri_instructions
        c.idleWakeups = ri.ri_pkg_idle_wkups
        c.interruptWakeups = ri.ri_interrupt_wkups
        c.diskRead = ri.ri_diskio_bytesread
        c.diskWrite = ri.ri_diskio_byteswritten
        c.footprint = ri.ri_phys_footprint
        c.resident = ri.ri_resident_size
        return true
    }

    private func threadCount(_ pid: Int32) -> Int32 {
        var info = proc_taskinfo()
        let sz = Int32(MemoryLayout<proc_taskinfo>.size)
        let rc = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, sz)
        return rc == sz ? Int32(info.pti_threadnum) : 0
    }

    /// PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is not exported to Swift.
    private static let pathMax = 4 * Int(MAXPATHLEN)

    private func executablePath(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: Self.pathMax)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
        return String(cString: buf)
    }

    private func comm(_ kp: kinfo_proc) -> String {
        var kp = kp
        return withUnsafePointer(to: &kp.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: $0.pointee)) {
                String(cString: $0)
            }
        }
    }

    /// Keep locally-derived identity, take counters from the helper.
    private func merge(identity: ProcCounters, counters: ProcCounters) -> ProcCounters {
        var out = counters
        out.pid = identity.pid
        out.ppid = identity.ppid
        out.uid = identity.uid
        out.name = identity.name
        out.path = identity.path
        out.startAbs = identity.startAbs
        out.status = identity.status
        return out
    }

    /// Monotonic counters can still reset if a helper drops in or out mid-stream.
    private func rate(_ now: UInt64, _ then: UInt64, _ interval: TimeInterval) -> Double {
        guard now >= then else { return 0 }
        return Double(now - then) / interval
    }
}
