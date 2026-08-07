import SwiftUI
import AppKit

/// Activity Monitor's process inspector, denser. Re-reads the process from the live
/// snapshot each frame so its numbers move while open, and exposes the same Quit /
/// Force Quit actions from the toolbar's info button.
struct ProcessInspectorView: View {
    let pid: Int32
    @ObservedObject var model: AppModel
    var onQuit: (_ force: Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForceQuit = false
    @State private var about = ""

    private var row: ProcRow? { model.snapshot.processes.first { $0.pid == pid } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let row {
                header(row)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        aboutBlock
                        section("Identity", identityRows(row))
                        section("CPU & Energy", cpuRows(row))
                        section("Graphics", gpuRows(row))
                        section("Memory", memoryRows(row))
                        section("Activity", activityRows(row))
                    }
                    .padding(12)
                }
                Divider()
                footer(row)
            } else {
                exited
            }
        }
        .frame(width: 440, height: 560)
        .refractiveCanvas()
    }

    private func header(_ row: ProcRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.readable ? "app.dashed" : "lock.fill")
                .font(.system(size: 26))
                .foregroundStyle(row.readable ? Color.accentColor : VitalsTheme.warn)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text("PID \(row.pid) • \(model.userName(row.counters.uid))")
                    .font(VitalsTheme.monoSmall).foregroundStyle(.secondary)
            }
            // Resolved off the main thread, so the first read is usually empty and
            // the answer lands a moment later. Polled briefly rather than pushed:
            // the inspector is open for seconds and a notification for one string
            // is more machinery than the wait is worth.
            .task(id: row.pid) {
                about = ProcessDescriptions.shared.describe(row)
                for _ in 0..<20 where about.isEmpty {
                    try? await Task.sleep(for: .milliseconds(100))
                    about = ProcessDescriptions.shared.describe(row)
                }
            }
            Spacer()
        }
        .padding(12)
    }

    /// Sits in the scrolling body rather than in the header, because the text is a
    /// short paragraph rather than a subtitle. In the header it would have had to
    /// share a fixed-height row with the icon and the PID line, so a long entry
    /// either clipped or pushed the identifying line out of sight; here it gets the
    /// full width and grows downward like any other section.
    @ViewBuilder private var aboutBlock: some View {
        if !about.isEmpty {
            Text(about)
                .font(VitalsTheme.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: VitalsTheme.controlRadius, style: .continuous)
                        .fill(VitalsTheme.paneFill)
                )
        }
    }

    private var exited: some View {
        VStack(spacing: 10) {
            Image(systemName: "xmark.circle").font(.system(size: 30)).foregroundStyle(.secondary)
            Text("Process \(pid) has exited.").font(VitalsTheme.label)
            Button("Close") { dismiss() }.controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(_ row: ProcRow) -> some View {
        HStack(spacing: 8) {
            if !row.counters.path.isEmpty {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: row.counters.path)])
                }
                .controlSize(.small)
            }
            Spacer()
            Button("Quit") { onQuit(false) }.controlSize(.small)
            Button("Force Quit") { confirmForceQuit = true }
                .controlSize(.small)
                .tint(VitalsTheme.critical)
            Button("Close") { dismiss() }.controlSize(.small).keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .alert("Force quit \(row.name)?", isPresented: $confirmForceQuit) {
            Button("Force Quit", role: .destructive) { onQuit(true); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("PID \(row.pid) will be sent SIGKILL. Unsaved work is lost.")
        }
    }

    // MARK: - Rows

    private func identityRows(_ r: ProcRow) -> [(String, String)] {
        var rows: [(String, String)] = [
            ("Process ID", String(r.pid)),
            ("Parent PID", String(r.counters.ppid)),
            ("User", model.userName(r.counters.uid)),
            ("Status", statusText(r.counters.status)),
            ("Measured", r.readable ? "yes" : "no — needs helper"),
        ]
        if !r.counters.path.isEmpty { rows.append(("Path", r.counters.path)) }
        return rows
    }

    private func cpuRows(_ r: ProcRow) -> [(String, String)] {
        [
            ("CPU", Fmt.percent(r.cpuPercent)),
            ("Energy", Fmt.power(r.energyMilliwatts)),
            ("Performance-core share", r.performanceCoreShare > 0
                ? Fmt.percent(r.performanceCoreShare * 100, decimals: 0) : "—"),
            ("CPU time", Fmt.duration(Double(r.counters.cpuNs) / 1e9)),
            ("Cycles", bigNumber(r.counters.cycles)),
            ("Instructions", bigNumber(r.counters.instructions)),
        ]
    }

    private func gpuRows(_ r: ProcRow) -> [(String, String)] {
        [
            ("GPU", Fmt.percent(r.gpuPercent)),
            ("GPU time", r.counters.gpuNs > 0 ? Fmt.duration(Double(r.counters.gpuNs) / 1e9) : "—"),
        ]
    }

    private func memoryRows(_ r: ProcRow) -> [(String, String)] {
        [
            ("Memory (footprint)", r.counters.footprint > 0 ? Fmt.bytes(r.counters.footprint) : "—"),
            ("Resident size", r.counters.resident > 0 ? Fmt.bytes(r.counters.resident) : "—"),
        ]
    }

    private func activityRows(_ r: ProcRow) -> [(String, String)] {
        [
            ("Threads", String(r.counters.threads)),
            ("Idle wakeups/s", Fmt.count(r.idleWakeupsPerSec)),
            ("Interrupt wakeups/s", Fmt.count(r.interruptWakeupsPerSec)),
            ("Disk read/s", Fmt.rate(r.diskReadPerSec)),
            ("Disk write/s", Fmt.rate(r.diskWritePerSec)),
        ]
    }

    // MARK: - Building blocks

    private func section(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            VStack(spacing: 3) {
                ForEach(rows.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 8) {
                        Text(rows[i].0).font(VitalsTheme.labelSmall).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(rows[i].1).font(VitalsTheme.monoSmall)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                            .frame(maxWidth: 250, alignment: .trailing)
                    }
                }
            }
            .padding(9)
            .refractiveGlass(cornerRadius: VitalsTheme.cardRadius)
            .overlay(RoundedRectangle(cornerRadius: VitalsTheme.cardRadius)
                .stroke(VitalsTheme.border, lineWidth: 1))
        }
    }

    private func statusText(_ status: Int32) -> String {
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

    private func bigNumber(_ v: UInt64) -> String {
        guard v > 0 else { return "—" }
        let d = Double(v)
        switch d {
        case ..<1_000: return String(v)
        case ..<1_000_000: return String(format: "%.1f K", d / 1e3)
        case ..<1_000_000_000: return String(format: "%.1f M", d / 1e6)
        case ..<1_000_000_000_000: return String(format: "%.2f B", d / 1e9)
        default: return String(format: "%.2f T", d / 1e12)
        }
    }
}
