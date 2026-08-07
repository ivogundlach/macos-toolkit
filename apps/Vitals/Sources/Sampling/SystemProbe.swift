import Foundation
import Darwin

/// Whole-machine CPU, memory, disk and network counters.
///
/// Apple Silicon splits cores into performance and efficiency clusters
/// (`hw.perflevel0` / `hw.perflevel1`). Reporting them separately matters for drain
/// work: the same load costs several times more energy on a P core than an E core.
final class SystemProbe {
    struct CoreLoad: Identifiable {
        let id: Int
        let isPerformance: Bool
        var usage: Double        // 0...1
    }

    struct Memory {
        var total: UInt64 = 0
        var used: UInt64 = 0
        var wired: UInt64 = 0
        var compressed: UInt64 = 0
        var cached: UInt64 = 0
        var appMemory: UInt64 = 0
        var swapUsed: UInt64 = 0
        var swapTotal: UInt64 = 0
        /// Activity Monitor's pressure figure, 0...1.
        var pressure: Double = 0
    }

    struct IOTotals {
        var readBytesPerSec: Double = 0
        var writeBytesPerSec: Double = 0
        var inBytesPerSec: Double = 0
        var outBytesPerSec: Double = 0
    }

    struct Stats {
        var cores: [CoreLoad] = []
        var cpuUsage: Double = 0          // 0...1 across all cores
        var performanceUsage: Double = 0
        var efficiencyUsage: Double = 0
        var memory = Memory()
        var io = IOTotals()
        var loadAverage: [Double] = [0, 0, 0]
        var uptime: TimeInterval = 0
        var thermalPressure: String = "Nominal"
    }

    private var previousTicks: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
    private var previousNet: (inB: UInt64, outB: UInt64)?
    private var previousDisk: (read: UInt64, write: UInt64)?
    private var previousAt = Date()
    private let performanceCores: Int
    private let efficiencyCores: Int

    init() {
        performanceCores = SystemProbe.sysctlInt("hw.perflevel0.logicalcpu") ?? 0
        efficiencyCores = SystemProbe.sysctlInt("hw.perflevel1.logicalcpu") ?? 0
    }

    func sample() -> Stats {
        let now = Date()
        let interval = max(0.001, now.timeIntervalSince(previousAt))
        defer { previousAt = now }

        var s = Stats()
        s.cores = sampleCores()
        if !s.cores.isEmpty {
            s.cpuUsage = s.cores.reduce(0) { $0 + $1.usage } / Double(s.cores.count)
            let p = s.cores.filter(\.isPerformance)
            let e = s.cores.filter { !$0.isPerformance }
            s.performanceUsage = p.isEmpty ? 0 : p.reduce(0) { $0 + $1.usage } / Double(p.count)
            s.efficiencyUsage = e.isEmpty ? 0 : e.reduce(0) { $0 + $1.usage } / Double(e.count)
        }
        s.memory = sampleMemory()
        s.io = sampleIO(interval: interval)
        s.loadAverage = sampleLoadAverage()
        s.uptime = ProcessInfo.processInfo.systemUptime
        s.thermalPressure = thermalPressure()
        return s
    }

    // MARK: - CPU

    private func sampleCores() -> [CoreLoad] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &count, &info, &infoCount) == KERN_SUCCESS,
              let data = info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: data)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        var ticks: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
        var out: [CoreLoad] = []
        for i in 0..<Int(count) {
            let base = i * Int(CPU_STATE_MAX)
            let user = UInt32(bitPattern: data[base + Int(CPU_STATE_USER)])
            let system = UInt32(bitPattern: data[base + Int(CPU_STATE_SYSTEM)])
            let idle = UInt32(bitPattern: data[base + Int(CPU_STATE_IDLE)])
            let nice = UInt32(bitPattern: data[base + Int(CPU_STATE_NICE)])
            ticks.append((user, system, idle, nice))

            var usage = 0.0
            if i < previousTicks.count {
                let p = previousTicks[i]
                let dUser = Double(user &- p.user), dSystem = Double(system &- p.system)
                let dIdle = Double(idle &- p.idle), dNice = Double(nice &- p.nice)
                let total = dUser + dSystem + dIdle + dNice
                if total > 0 { usage = (dUser + dSystem + dNice) / total }
            }
            // The kernel orders performance cores first on Apple Silicon.
            out.append(CoreLoad(id: i, isPerformance: i < performanceCores, usage: usage))
        }
        previousTicks = ticks
        return out
    }

    // MARK: - Memory

    private func sampleMemory() -> Memory {
        var m = Memory()
        m.total = ProcessInfo.processInfo.physicalMemory

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let rc = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard rc == KERN_SUCCESS else { return m }

        let page = UInt64(vm_kernel_page_size)
        m.wired = UInt64(stats.wire_count) * page
        m.compressed = UInt64(stats.compressor_page_count) * page
        m.cached = UInt64(stats.external_page_count) * page
        m.appMemory = UInt64(stats.internal_page_count &- stats.purgeable_count) * page
        m.used = m.appMemory + m.wired + m.compressed
        // Matches Activity Monitor's pressure: what cannot be reclaimed cheaply.
        m.pressure = m.total > 0 ? Double(m.wired + m.compressed) / Double(m.total) : 0

        var xsw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 {
            m.swapUsed = xsw.xsu_used
            m.swapTotal = xsw.xsu_total
        }
        return m
    }

    // MARK: - Disk and network

    private func sampleIO(interval: TimeInterval) -> IOTotals {
        var io = IOTotals()

        let net = networkTotals()
        if let prev = previousNet {
            io.inBytesPerSec = delta(net.inB, prev.inB) / interval
            io.outBytesPerSec = delta(net.outB, prev.outB) / interval
        }
        previousNet = net

        let disk = diskTotals()
        if let prev = previousDisk {
            io.readBytesPerSec = delta(disk.read, prev.read) / interval
            io.writeBytesPerSec = delta(disk.write, prev.write) / interval
        }
        previousDisk = disk
        return io
    }

    /// Sum of all non-loopback interfaces.
    private func networkTotals() -> (inB: UInt64, outB: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, 6, nil, &size, nil, 0) == 0, size > 0 else { return (0, 0) }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 6, &buf, &size, nil, 0) == 0 else { return (0, 0) }

        var inB: UInt64 = 0, outB: UInt64 = 0
        buf.withUnsafeBytes { raw in
            var offset = 0
            while offset < size {
                let hdr = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: if_msghdr.self)
                let len = Int(hdr.pointee.ifm_msglen)
                guard len > 0 else { break }
                if hdr.pointee.ifm_type == RTM_IFINFO2 {
                    let m2 = raw.baseAddress!.advanced(by: offset)
                        .assumingMemoryBound(to: if_msghdr2.self)
                    // Skip loopback so local traffic does not inflate the totals.
                    if m2.pointee.ifm_data.ifi_type != UInt8(IFT_LOOP) {
                        inB &+= m2.pointee.ifm_data.ifi_ibytes
                        outB &+= m2.pointee.ifm_data.ifi_obytes
                    }
                }
                offset += len
            }
        }
        return (inB, outB)
    }

    /// Aggregate bytes across every block storage driver.
    private func diskTotals() -> (read: UInt64, write: UInt64) {
        var read: UInt64 = 0, write: UInt64 = 0
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS
        else { return (0, 0) }
        defer { IOObjectRelease(iter) }

        while case let drive = IOIteratorNext(iter), drive != 0 {
            defer { IOObjectRelease(drive) }
            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(drive, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = propsRef?.takeRetainedValue() as? [String: Any],
                  let stats = props["Statistics"] as? [String: Any] else { continue }
            read &+= UInt64(max(0, (stats["Bytes (Read)"] as? NSNumber)?.doubleValue ?? 0))
            write &+= UInt64(max(0, (stats["Bytes (Write)"] as? NSNumber)?.doubleValue ?? 0))
        }
        return (read, write)
    }

    // MARK: - Misc

    private func sampleLoadAverage() -> [Double] {
        var avg = [Double](repeating: 0, count: 3)
        getloadavg(&avg, 3)
        return avg
    }

    private func thermalPressure() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private func delta(_ now: UInt64, _ then: UInt64) -> Double {
        now >= then ? Double(now - then) : 0
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}
