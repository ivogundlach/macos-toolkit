import Foundation

/// Compact formatters. Density depends on short strings, so these favour two or
/// three significant digits over exactness.
enum Fmt {
    static func bytes(_ value: UInt64) -> String { bytes(Double(value)) }

    static func bytes(_ value: Double) -> String {
        let v = abs(value)
        switch v {
        case ..<1024: return "\(Int(value)) B"
        case ..<(1024 * 1024): return String(format: "%.0f K", value / 1024)
        case ..<(1024 * 1024 * 1024): return String(format: "%.1f M", value / 1_048_576)
        case ..<(1024.0 * 1024 * 1024 * 1024): return String(format: "%.2f G", value / 1_073_741_824)
        default: return String(format: "%.2f T", value / 1_099_511_627_776)
        }
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytesPerSecond < 1 ? "—" : bytes(bytesPerSecond) + "/s"
    }

    static func percent(_ value: Double, decimals: Int = 1) -> String {
        value <= 0 ? "—" : String(format: "%.\(decimals)f%%", value)
    }

    /// Milliwatts below a watt, watts above, so the column stays narrow.
    static func power(_ milliwatts: Double) -> String {
        let v = abs(milliwatts)
        if v < 0.05 { return "—" }
        if v < 1000 { return String(format: "%.0f mW", milliwatts) }
        return String(format: "%.2f W", milliwatts / 1000)
    }

    static func watts(_ value: Double, decimals: Int = 2) -> String {
        value <= 0.001 ? "—" : String(format: "%.\(decimals)f W", value)
    }

    static func energy(_ joules: Double) -> String {
        let v = abs(joules)
        if v < 1 { return String(format: "%.0f mJ", joules * 1000) }
        if v < 1000 { return String(format: "%.1f J", joules) }
        if v < 3600 { return String(format: "%.2f kJ", joules / 1000) }
        return String(format: "%.3f Wh", joules / 3600)
    }

    static func wattHours(_ joules: Double) -> String {
        String(format: "%.3f Wh", joules / 3600)
    }

    static func count(_ value: Double) -> String {
        value < 0.05 ? "—" : (value < 10 ? String(format: "%.1f", value) : String(format: "%.0f", value))
    }

    static func bigNumber(_ value: UInt64) -> String {
        guard value > 0 else { return "—" }
        let v = Double(value)
        switch v {
        case ..<1_000: return String(value)
        case ..<1_000_000: return String(format: "%.1f K", v / 1e3)
        case ..<1_000_000_000: return String(format: "%.1f M", v / 1e6)
        case ..<1_000_000_000_000: return String(format: "%.2f B", v / 1e9)
        default: return String(format: "%.2f T", v / 1e12)
        }
    }

    static func processStatus(_ status: Int32) -> String {
        // Values from <sys/proc.h>: SIDL 1, SRUN 2, SSLEEP 3, SSTOP 4, SZOMB 5.
        switch status {
        case 1: return "starting"
        case 2: return "running"
        case 3: return "sleeping"
        case 4: return "stopped"
        case 5: return "zombie"
        default: return "unknown"
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        return "\(s / 86400)d \((s % 86400) / 3600)h"
    }

    static func minutes(_ value: Int) -> String {
        value <= 0 ? "—" : (value < 60 ? "\(value)m" : "\(value / 60)h \(value % 60)m")
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func shortDateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "d MMM HH:mm"
        return f.string(from: date)
    }
}
