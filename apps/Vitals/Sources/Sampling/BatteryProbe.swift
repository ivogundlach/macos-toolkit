import Foundation
import IOKit

/// Battery and whole-system power, read from `AppleSmartBattery`.
///
/// `PowerTelemetryData.SystemLoad` is the machine's actual draw in milliwatts —
/// the ground truth a drain diagnosis needs. All of it is readable unprivileged.
struct BatteryProbe {
    struct Stats {
        var present = false
        var charging = false
        var externalConnected = false
        var percent: Double = 0          // 0...100
        var voltage: Double = 0          // volts
        var amperage: Double = 0         // amps, negative when discharging
        var cycleCount: Int = 0
        var designCapacity: Int = 0      // mAh
        var fullChargeCapacity: Int = 0  // mAh
        var temperature: Double = 0      // celsius
        var timeRemaining: Int = 0       // minutes, 0 when unknown

        /// Whole-system draw in watts.
        var systemLoadWatts: Double = 0
        /// Power arriving from the adapter, in watts.
        var adapterWatts: Double = 0
        /// Power into (positive) or out of (negative) the battery, in watts.
        var batteryWatts: Double = 0

        /// Capacity retained versus the design spec (0...1).
        var health: Double {
            guard designCapacity > 0 else { return 0 }
            return Double(fullChargeCapacity) / Double(designCapacity)
        }

        /// Drain in watts, positive only while actually discharging.
        var dischargeWatts: Double {
            guard !externalConnected else { return 0 }
            return max(0, systemLoadWatts)
        }
    }

    static func sample() -> Stats {
        var s = Stats()
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return s }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let p = propsRef?.takeRetainedValue() as? [String: Any] else { return s }

        s.present = true
        s.externalConnected = (p["ExternalConnected"] as? Bool) ?? false
        s.charging = (p["IsCharging"] as? Bool) ?? false
        s.voltage = num(p["Voltage"]) / 1000.0
        s.amperage = num(p["Amperage"]) / 1000.0
        s.cycleCount = Int(num(p["CycleCount"]))
        s.temperature = num(p["Temperature"]) / 100.0
        s.timeRemaining = Int(num(p["TimeRemaining"]))
        if s.timeRemaining >= 65535 { s.timeRemaining = 0 }   // sentinel for "calculating"

        if let bd = p["BatteryData"] as? [String: Any] {
            s.designCapacity = Int(num(bd["DesignCapacity"]))
            s.fullChargeCapacity = Int(num(bd["FullChargeCapacity"]))
            s.percent = num(bd["CurrentCapacity"])
        }
        if s.percent == 0 { s.percent = num(p["CurrentCapacity"]) }

        if let t = p["PowerTelemetryData"] as? [String: Any] {
            s.systemLoadWatts = num(t["SystemLoad"]) / 1000.0
            s.adapterWatts = num(t["SystemPowerIn"]) / 1000.0
            s.batteryWatts = num(t["BatteryPower"]) / 1000.0
        }
        // Fall back to V*I when the telemetry block is absent.
        if s.systemLoadWatts == 0 && s.voltage > 0 {
            s.systemLoadWatts = abs(s.voltage * s.amperage)
        }
        return s
    }

    private static func num(_ any: Any?) -> Double {
        if let n = any as? NSNumber { return n.doubleValue }
        if let b = any as? Bool { return b ? 1 : 0 }
        return 0
    }
}
