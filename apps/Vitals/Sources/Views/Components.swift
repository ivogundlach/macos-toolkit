import SwiftUI

/// Compact line chart. Autoscales to its own range unless a maximum is supplied.
struct Sparkline: View {
    var values: [Double]
    var tint: Color
    var maximum: Double? = nil
    var filled = true

    var body: some View {
        GeometryReader { geo in
            let top = maximum ?? max(values.max() ?? 1, 0.0001)
            let n = values.count
            if n > 1 {
                let step = geo.size.width / CGFloat(n - 1)
                let points = values.enumerated().map { i, v in
                    CGPoint(x: CGFloat(i) * step,
                            y: geo.size.height * (1 - CGFloat(min(1, max(0, v / top)))))
                }
                if filled {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: geo.size.height))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                }
                Path { p in
                    p.move(to: points[0])
                    points.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            }
        }
    }
}

/// Bucketed bar chart: one bar per hour or per day. Unlike a sparkline it holds
/// still between reloads, which is the point — these views are read, not watched.
struct BarChart: View {
    struct Datum: Identifiable {
        let id: Int
        /// nil means "nothing recorded in this bucket", drawn as a gap rather than a zero.
        let value: Double?
        let label: String
    }

    var data: [Datum]
    var tint: Color
    /// Fixed ceiling, or nil to scale to the tallest bar.
    var maximum: Double? = nil

    var body: some View {
        let top = maximum ?? max(data.compactMap(\.value).max() ?? 1, 0.0001)
        let stride = labelStride
        VStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: barSpacing) {
                ForEach(data) { datum in
                    GeometryReader { geo in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.05))
                            if let value = datum.value {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(tint.opacity(0.85))
                                    .frame(height: max(1, geo.size.height
                                                       * CGFloat(min(1, max(0, value / top)))))
                            }
                        }
                    }
                }
            }
            .frame(height: 74)

            HStack(spacing: barSpacing) {
                ForEach(data) { datum in
                    Text(datum.id % stride == 0 ? datum.label : "")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var barSpacing: CGFloat { data.count > 14 ? 2 : 4 }

    /// Label every bar when they fit, otherwise thin them out so they never overlap.
    private var labelStride: Int {
        switch data.count {
        case ..<9: return 1
        case ..<16: return 2
        case ..<26: return 4
        default: return 5
        }
    }
}

/// Labelled horizontal bar used throughout the dashboards.
struct MetricBar: View {
    var label: String
    var detail: String
    var fraction: Double
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(label).font(VitalsTheme.labelSmall).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(detail).font(VitalsTheme.monoSmall)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(tint)
                        .frame(width: geo.size.width * CGFloat(min(1, max(0, fraction))))
                }
            }
            .frame(height: 5)
        }
    }
}

/// Headline number with an optional trend line underneath.
struct StatTile: View {
    var title: String
    var value: String
    var caption: String? = nil
    var tint: Color
    var symbol: String? = nil
    var trend: [Double] = []
    var trendMaximum: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(tint)
                }
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let caption {
                Text(caption).font(VitalsTheme.labelSmall).foregroundStyle(.secondary).lineLimit(1)
            }
            if trend.count > 1 {
                Sparkline(values: trend, tint: tint, maximum: trendMaximum).frame(height: 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .refractiveGlass(cornerRadius: VitalsTheme.cardRadius)
        .overlay(RoundedRectangle(cornerRadius: VitalsTheme.cardRadius)
            .stroke(VitalsTheme.border, lineWidth: 1))
    }
}

/// Titled container for a group of related readouts.
struct SectionCard<Content: View>: View {
    var title: String
    var accessory: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(VitalsTheme.sectionTitle).foregroundStyle(.secondary)
                Spacer()
                if let accessory {
                    Text(accessory).font(VitalsTheme.monoSmall).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(10)
        .refractiveGlass(cornerRadius: VitalsTheme.groupRadius)
        .overlay(RoundedRectangle(cornerRadius: VitalsTheme.groupRadius)
            .stroke(VitalsTheme.border, lineWidth: 1))
    }
}

/// Per-core load grid. Performance and efficiency clusters are separated because
/// the same work costs very different energy on each.
struct CoreGrid: View {
    var cores: [SystemProbe.CoreLoad]

    var body: some View {
        let performance = cores.filter(\.isPerformance)
        let efficiency = cores.filter { !$0.isPerformance }
        VStack(alignment: .leading, spacing: 6) {
            if !performance.isEmpty { cluster("Performance", performance) }
            if !efficiency.isEmpty { cluster("Efficiency", efficiency) }
        }
    }

    private func cluster(_ name: String, _ list: [SystemProbe.CoreLoad]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(name).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Text("\(list.count) cores").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            // Fixed-width bars so the efficiency cluster lines up under the
            // performance cluster instead of stretching to fill the row.
            HStack(spacing: 3) {
                ForEach(list) { core in
                    VStack(spacing: 2) {
                        GeometryReader { geo in
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.07))
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(VitalsTheme.loadColor(core.usage))
                                    .frame(height: max(1, geo.size.height * CGFloat(core.usage)))
                            }
                        }
                        .frame(width: 34, height: 26)
                        Text("\(Int(core.usage * 100))")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// Every useful process field Vitals already samples. The persisted ordered list of
/// these values is shared by Settings, the header, and every row so they cannot drift.
enum ProcColumn: String, CaseIterable, Identifiable, Codable {
    case pid, ppid, name, user, uid, path, measured, status, started
    case cpu, cpuTime, pCoreTime, energy, energyTotal, pcore, gpu, gpuTime
    case memory, resident, wakeups, interruptWakeups, diskIO, diskRead, diskWrite
    case threads, cycles, instructions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pid: return "PID"
        case .ppid: return "PPID"
        case .name: return "Process"
        case .user: return "User"
        case .uid: return "UID"
        case .path: return "Executable path"
        case .measured: return "Measured"
        case .status: return "Status"
        case .started: return "Started"
        case .cpu: return "CPU"
        case .cpuTime: return "CPU time"
        case .pCoreTime: return "P-core time"
        case .energy: return "Energy"
        case .energyTotal: return "Energy total"
        case .pcore: return "P-core"
        case .gpu: return "GPU"
        case .gpuTime: return "GPU time"
        case .memory: return "Memory"
        case .resident: return "Resident"
        case .wakeups: return "Wake/s"
        case .interruptWakeups: return "Intr/s"
        case .diskIO: return "Disk R/W"
        case .diskRead: return "Disk read"
        case .diskWrite: return "Disk write"
        case .threads: return "Thr"
        case .cycles: return "Cycles"
        case .instructions: return "Instructions"
        }
    }

    var description: String {
        switch self {
        case .pid: return "Process identifier"
        case .ppid: return "Parent process identifier"
        case .name: return "Process or executable name"
        case .user: return "Owning user name"
        case .uid: return "Owning numeric user ID"
        case .path: return "Full executable path"
        case .measured: return "Whether protected counters are readable"
        case .status: return "Running, sleeping, stopped, or zombie"
        case .started: return "Process launch date and time"
        case .cpu: return "Current CPU utilization"
        case .cpuTime: return "Cumulative CPU time"
        case .pCoreTime: return "Cumulative performance-core CPU time"
        case .energy: return "Current attributed process power"
        case .energyTotal: return "Cumulative measured process energy"
        case .pcore: return "Share of energy spent on performance cores"
        case .gpu: return "Current per-process GPU utilization"
        case .gpuTime: return "Cumulative Metal GPU time"
        case .memory: return "Physical footprint used for memory accounting"
        case .resident: return "Resident memory size"
        case .wakeups: return "Package idle wakeups per second"
        case .interruptWakeups: return "Interrupt wakeups per second"
        case .diskIO: return "Combined read and write rates"
        case .diskRead: return "Disk read rate"
        case .diskWrite: return "Disk write rate"
        case .threads: return "Current thread count"
        case .cycles: return "Cumulative CPU cycles"
        case .instructions: return "Cumulative CPU instructions"
        }
    }

    var width: CGFloat {
        switch self {
        case .pid, .ppid, .uid: return 52
        case .name: return 210
        case .user: return 82
        case .path: return 280
        case .measured: return 74
        case .status: return 70
        case .started: return 100
        case .cpu: return 56
        case .cpuTime, .pCoreTime, .energyTotal, .gpuTime, .cycles, .diskRead, .diskWrite: return 72
        case .energy: return 66
        case .pcore: return 50
        case .gpu: return 54
        case .memory, .resident, .interruptWakeups: return 64
        case .wakeups: return 54
        case .diskIO: return 92
        case .threads: return 38
        case .instructions: return 84
        }
    }

    var sort: ProcessSort {
        switch self {
        case .pid: return .pid
        case .ppid: return .ppid
        case .name: return .name
        case .user: return .user
        case .uid: return .uid
        case .path: return .path
        case .measured: return .measured
        case .status: return .status
        case .started: return .started
        case .cpu: return .cpu
        case .cpuTime: return .cpuTime
        case .pCoreTime: return .pCoreTime
        case .energy: return .energy
        case .energyTotal: return .energyTotal
        case .pcore: return .performanceCoreShare
        case .gpu: return .gpu
        case .gpuTime: return .gpuTime
        case .memory: return .memory
        case .resident: return .resident
        case .wakeups: return .wakeups
        case .interruptWakeups: return .interruptWakeups
        case .diskIO: return .diskIO
        case .diskRead: return .diskRead
        case .diskWrite: return .diskWrite
        case .threads: return .threads
        case .cycles: return .cycles
        case .instructions: return .instructions
        }
    }

    var alignment: Alignment {
        switch self {
        case .name, .user, .path, .measured, .status, .started: return .leading
        default: return .trailing
        }
    }
}

enum ProcColumns {
    /// Read and write are separate columns: a single cell holding both rates changes
    /// width as each side updates, which makes the number unreadable at a glance.
    static let defaults: [ProcColumn] = [
        .pid, .name, .user, .cpu, .energy, .pcore, .gpu, .memory,
        .wakeups, .diskRead, .diskWrite, .threads,
    ]

    /// Existing installs persisted the combined column; split it in place so the
    /// change reaches them without discarding the rest of their layout.
    static func migrated(_ columns: [ProcColumn]) -> [ProcColumn] {
        var out = columns
        if let index = out.firstIndex(of: .diskIO) {
            out.replaceSubrange(index...index, with: [.diskRead, .diskWrite])
        }
        var seen = Set<ProcColumn>()
        return out.filter { seen.insert($0).inserted }
    }
}
