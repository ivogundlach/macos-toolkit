import Foundation
import Darwin

// Vitals privileged helper.
//
// Runs as root under launchd for one reason: macOS returns EPERM from
// proc_pid_rusage for processes owned by another user, which hides every root
// daemon from an unprivileged monitor.
//
// Security posture, deliberately minimal:
//   * takes no arguments, reads no stdin, opens no sockets or IPC ports
//   * performs exactly one privileged operation: reading kernel counters
//   * publishes to a single world-readable file, written atomically
//   * never executes, spawns, deletes or modifies anything else
// There is therefore no input an unprivileged process can supply to influence it.

let outputPath = "/var/run/vitals-counters.json"
let interval: TimeInterval = 5
let maxPhysicalFootprint: UInt64 = 16 * 1024 * 1024

/// Snapshot every process the kernel will describe.
func collect() -> [[String: Any]] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
    size += MemoryLayout<kinfo_proc>.stride * 32
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
    guard sysctl(&mib, 3, &procs, &size, nil, 0) == 0 else { return [] }
    let count = size / MemoryLayout<kinfo_proc>.stride

    var out: [[String: Any]] = []
    out.reserveCapacity(count)
    for i in 0..<count {
        let pid = procs[i].kp_proc.p_pid
        guard pid > 0 else { continue }
        var ri = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard rc == 0 else { continue }
        out.append([
            "pid": Int(pid),
            "cpu_ns": ri.ri_user_time &+ ri.ri_system_time,
            "pcpu_ns": ri.ri_user_ptime &+ ri.ri_system_ptime,
            "energy_nj": ri.ri_energy_nj,
            "penergy_nj": ri.ri_penergy_nj,
            "cycles": ri.ri_cycles,
            "instructions": ri.ri_instructions,
            "idle_wkups": ri.ri_pkg_idle_wkups,
            "intr_wkups": ri.ri_interrupt_wkups,
            "disk_r": ri.ri_diskio_bytesread,
            "disk_w": ri.ri_diskio_byteswritten,
            "footprint": ri.ri_phys_footprint,
            "resident": ri.ri_resident_size,
        ])
    }
    return out
}

/// Write via a temporary file and rename, so a reader never sees a partial document.
func publish(_ processes: [[String: Any]]) {
    let payload: [String: Any] = [
        "generated": Date().timeIntervalSince1970,
        "processes": processes,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
    let temporary = outputPath + ".tmp"
    guard FileManager.default.createFile(atPath: temporary, contents: data,
                                         attributes: [.posixPermissions: 0o644]) else { return }
    _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: outputPath),
                                               withItemAt: URL(fileURLWithPath: temporary))
}

/// Launchd immediately restarts the helper if it ever exceeds its small expected
/// footprint. This is a last-resort guard against future regressions; the normal
/// steady-state footprint is only a few megabytes.
func physicalFootprint() -> UInt64 {
    var ri = rusage_info_v6()
    let rc = withUnsafeMutablePointer(to: &ri) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0)
        }
    }
    return rc == 0 ? ri.ri_phys_footprint : 0
}

while true {
    // Foundation's JSON bridge creates autoreleased Objective-C objects. A
    // command-line daemon has no application run loop to drain them for us.
    autoreleasepool {
        publish(collect())
    }
    if physicalFootprint() > maxPhysicalFootprint {
        exit(EXIT_FAILURE)
    }
    Thread.sleep(forTimeInterval: interval)
}
