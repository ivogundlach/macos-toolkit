import Foundation
import IOKit

/// GPU sampling.
///
/// Device-wide load comes from the accelerator's `PerformanceStatistics`.
/// Per-process attribution comes from `AGXDeviceUserClient` nodes: each one records
/// `IOUserClientCreator` ("pid 446, WindowServer") and an `AppUsage` array whose
/// entries carry `accumulatedGPUTime` in nanoseconds per Metal command queue.
/// Both are readable without elevated privileges.
struct GPUProbe {
    struct DeviceStats {
        var deviceUtilization: Double = 0   // percent
        var rendererUtilization: Double = 0
        var tilerUtilization: Double = 0
        var inUseMemory: UInt64 = 0
        var allocatedMemory: UInt64 = 0
        var coreCount: Int = 0
        var name: String = "GPU"
    }

    /// Cumulative GPU nanoseconds per pid, summed over that pid's command queues.
    typealias ProcessGPUTime = [Int32: UInt64]

    static func sampleDevice() -> DeviceStats {
        var stats = DeviceStats()
        let matching = IOServiceMatching("IOAccelerator")
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return stats
        }
        defer { IOObjectRelease(iter) }

        while case let service = IOIteratorNext(iter), service != 0 {
            defer { IOObjectRelease(service) }
            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = propsRef?.takeRetainedValue() as? [String: Any] else { continue }

            if let model = props["model"] as? Data,
               let s = String(data: model, encoding: .utf8) {
                stats.name = s.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            } else if let model = props["model"] as? String {
                stats.name = model
            }
            stats.coreCount = (props["gpu-core-count"] as? Int) ?? stats.coreCount

            if let perf = props["PerformanceStatistics"] as? [String: Any] {
                stats.deviceUtilization = number(perf["Device Utilization %"])
                stats.rendererUtilization = number(perf["Renderer Utilization %"])
                stats.tilerUtilization = number(perf["Tiler Utilization %"])
                stats.inUseMemory = UInt64(max(0, number(perf["In use system memory"])))
                stats.allocatedMemory = UInt64(max(0, number(perf["Alloc system memory"])))
            }
        }
        return stats
    }

    /// Walk every AGXDeviceUserClient and total accumulated GPU time per creating pid.
    static func sampleProcesses() -> ProcessGPUTime {
        var out: ProcessGPUTime = [:]
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS
        else { return out }
        defer { IOObjectRelease(iter) }

        while case let accel = IOIteratorNext(iter), accel != 0 {
            defer { IOObjectRelease(accel) }
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accel, kIOServicePlane, &children) == KERN_SUCCESS
            else { continue }
            defer { IOObjectRelease(children) }

            while case let client = IOIteratorNext(children), client != 0 {
                defer { IOObjectRelease(client) }
                var propsRef: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(client, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let props = propsRef?.takeRetainedValue() as? [String: Any],
                      let creator = props["IOUserClientCreator"] as? String,
                      let pid = parsePID(creator) else { continue }

                guard let usage = props["AppUsage"] as? [[String: Any]] else { continue }
                var total: UInt64 = 0
                for entry in usage {
                    total &+= UInt64(max(0, number(entry["accumulatedGPUTime"])))
                }
                if total > 0 { out[pid, default: 0] &+= total }
            }
        }
        return out
    }

    /// "pid 446, WindowServer" -> 446
    private static func parsePID(_ creator: String) -> Int32? {
        guard creator.hasPrefix("pid ") else { return nil }
        let rest = creator.dropFirst(4)
        let digits = rest.prefix { $0.isNumber }
        return Int32(digits)
    }

    private static func number(_ any: Any?) -> Double {
        if let n = any as? NSNumber { return n.doubleValue }
        return 0
    }
}
