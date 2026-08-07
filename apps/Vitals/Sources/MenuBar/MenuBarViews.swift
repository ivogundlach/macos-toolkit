import SwiftUI

/// What actually sits in the menu bar. Renders only the metrics the user enabled,
/// in their chosen order.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        // MenuBarExtra truncates a multi-view label to roughly its first element, so
        // the whole readout has to be a single Text with the symbols interpolated in.
        if model.menuBarMetrics.isEmpty {
            Image(systemName: "gauge.medium")
        } else {
            label.monospacedDigit()
        }
    }

    private var label: Text {
        var result = Text("")
        for (index, metric) in model.menuBarMetrics.enumerated() {
            if index > 0 { result = result + Text("  ") }
            if model.showMenuBarLabels {
                result = result + Text(metric.shortLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary) + Text(" ")
            }
            result = result + Text(metric.render(model.snapshot))
        }
        return result
    }
}

/// The dropdown panel: a compact summary plus the findings that matter.
struct MenuBarPanel: View {
    @ObservedObject var model: AppModel

    private var s: Snapshot { model.snapshot }

    /// Tiles wrap 4-across at this width; larger fonts throughout for readability.
    private let columns = [GridItem(.adaptive(minimum: 66), spacing: 7)]

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header

            if !model.panelMetrics.isEmpty {
                LazyVGrid(columns: columns, spacing: 7) {
                    ForEach(model.panelMetrics) { metric in
                        tile(metric)
                    }
                }
            }

            // Always render enabled sections, even when empty, so changing samples
            // never makes the buttons below the lists jump.
            ForEach(model.panelProcessMetrics) { metric in
                Divider()
                list(title: metric.panelTitle,
                     rows: metric.rows(in: s, limit: model.panelListSize.count)) { row in
                    metric.formattedValue(for: row)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button("Open Vitals") { MainWindow.show() }
                    .buttonStyle(.borderedProminent).controlSize(.regular)

                // SettingsLink is the only reliable way to open the Settings scene
                // from a MenuBarExtra; the private showSettingsWindow: selector is
                // silently dropped on recent macOS. The gesture just brings the app
                // forward, since a menu-bar-only launch leaves it in the background.
                SettingsLink {
                    Text("Settings")
                }
                .controlSize(.regular)
                .simultaneousGesture(TapGesture().onEnded {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                })

                Spacer()

                // Route through the explicit-quit path; a plain terminate would be
                // refused by the termination gate and do nothing.
                Button("Quit") { AppControl.quit() }
                    .controlSize(.regular)
            }
        }
        .padding(13)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("Vitals").font(.system(size: 14, weight: .semibold))
            Spacer()
            if s.battery.present {
                HStack(spacing: 4) {
                    Image(systemName: s.battery.externalConnected
                          ? "battery.100.bolt" : "battery.75")
                        .font(.system(size: 11))
                    Text("\(Int(s.battery.percent))%")
                        .font(.system(size: 12, weight: .medium))
                    if !s.battery.externalConnected, s.battery.timeRemaining > 0 {
                        Text("• \(Fmt.minutes(s.battery.timeRemaining))")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func tile(_ metric: MenuBarMetric) -> some View {
        VStack(spacing: 2) {
            Text(metric.shortLabel)
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(metric.render(s))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(metric.tint).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(metric.tint.opacity(0.12)))
    }

    private var processFontSize: CGFloat { CGFloat(model.panelProcessFontSize) }
    private var panelRowHeight: CGFloat { processFontSize + 7 }
    /// Cap on rows shown for "All" before the list scrolls internally.
    private static let panelAllCap = 12

    /// A process list with a *stable* height. Fixed sizes reserve exactly N rows so
    /// rows dropping to zero (and out of the >0-filtered top-N) leave the panel — and
    /// the buttons beneath it — perfectly still. "All" sizes to its contents up to a
    /// cap, then scrolls.
    private func list(title: String, rows: [ProcRow],
                      value: @escaping (ProcRow) -> String) -> some View {
        let size = model.panelListSize
        let rowH = panelRowHeight
        return VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: max(9, processFontSize - 1), weight: .semibold))
                .foregroundStyle(.secondary)

            if rows.isEmpty {
                Text("nothing measurable")
                    .font(.system(size: processFontSize)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: size.scrolls ? rowH : CGFloat(size.count) * rowH, alignment: .top)
            } else if size.scrolls {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row(for: $0, value: value) }
                    }
                }
                .frame(height: CGFloat(min(rows.count, Self.panelAllCap)) * rowH)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { row(for: $0, value: value) }
                }
                .frame(height: CGFloat(size.count) * rowH, alignment: .top)
            }
        }
    }

    private func row(for row: ProcRow, value: (ProcRow) -> String) -> some View {
        HStack(spacing: 6) {
            Text(row.name).font(.system(size: processFontSize))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(value(row))
                .font(.system(size: processFontSize, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(height: panelRowHeight)
    }
}
