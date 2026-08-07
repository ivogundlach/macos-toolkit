import SwiftUI

/// Processes is the live tab. Every other tab is a resource seen retrospectively —
/// named after the resource itself, because "History" said when the numbers came
/// from rather than what they were about.
enum VitalsTab: Hashable, Identifiable {
    case processes
    case resource(ResourceKind)

    static let allCases: [VitalsTab] = [.processes] + ResourceKind.allCases.map(VitalsTab.resource)

    var id: String {
        switch self {
        case .processes: return "processes"
        case .resource(let kind): return kind.rawValue
        }
    }

    var title: String {
        switch self {
        case .processes: return "Processes"
        case .resource(let kind): return kind.title
        }
    }

    var symbol: String {
        switch self {
        case .processes: return "list.bullet.rectangle"
        case .resource(let kind): return kind.symbol
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var tab: VitalsTab = .processes
    @Namespace private var tabGlass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
        }
        .refractiveCanvas()
        .frame(minWidth: 940, minHeight: 560)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(VitalsTab.allCases) { item in
                        // No `withAnimation`: a global transaction also animates the
                        // content the tab swaps in. The `.animation` below scopes
                        // the pill morph to the tab bar instead.
                        Button {
                            tab = item
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: item.symbol).font(.system(size: 10))
                                Text(item.title).font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background {
                                // Solid tint, not tinted glass: in light appearance the
                                // glass tint goes pale and white-on-it stops being legible.
                                if tab == item {
                                    RoundedRectangle(cornerRadius: VitalsTheme.controlRadius)
                                        .fill(Color.accentColor)
                                        .matchedGeometryEffect(id: "tabPill", in: tabGlass)
                                }
                            }
                            .foregroundStyle(tab == item ? Color.white : Color.primary)
                            .contentShape(Rectangle())
                        }
            .buttonStyle(.plain)
            .focusEffectDisabled()   // no system focus ring; selection shows via the fill
            }

            Spacer()

            // Always-visible vitals so the header is useful on every tab.
            HStack(spacing: 10) {
                headline("CPU", Fmt.percent(model.snapshot.system.cpuUsage * 100, decimals: 0),
                         VitalsTheme.cpu)
                headline("GPU", Fmt.percent(model.snapshot.gpu.deviceUtilization, decimals: 0),
                         VitalsTheme.gpu)
                headline("PWR", Fmt.watts(model.snapshot.power.systemWatts, decimals: 1),
                         VitalsTheme.energy)
                if model.snapshot.battery.present {
                    headline("BAT", "\(Int(model.snapshot.battery.percent))%", VitalsTheme.battery)
                }
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(VitalsTheme.sidebar)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: tab)
    }

    private func headline(_ title: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(tint).monospacedDigit()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .processes:
            ProcessesView(model: model)
        case .resource(let kind):
            // Keyed by kind so switching tabs makes a fresh view that loads its own
            // window, rather than reusing the previous resource's state.
            ResourceHistoryView(model: model, kind: kind).id(kind)
        }
    }
}
