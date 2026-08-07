import SwiftUI

struct ContentView: View {
    private var model: AppModel { AppModel.shared }
    @Namespace private var tabGlass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let tabs = ["Overview", "Senate", "House", "President", "Apportionment", "Redistrict", "Forecast"]
    private let icons = ["square.grid.2x2", "building.columns", "person.3",
                         "flag", "map", "rectangle.split.3x3", "chart.bar.xaxis"]
    // Per-tab hues for the selected fill and unselected icons. Deliberately
    // offset from the reserved dem/rep party colors.
    private let tabTints: [Color] = [
        Color(red: 0.12, green: 0.43, blue: 0.52),   // Overview — civic teal
        Color(red: 0.40, green: 0.38, blue: 0.80),   // Senate — indigo
        Color(red: 0.16, green: 0.55, blue: 0.38),   // House — emerald
        Color(red: 0.58, green: 0.34, blue: 0.72),   // President — violet
        Color(red: 0.80, green: 0.52, blue: 0.12),   // Apportionment — amber
        Color(red: 0.11, green: 0.55, blue: 0.66),   // Redistrict — cyan
        Color(red: 0.76, green: 0.38, blue: 0.28),   // Forecast — terracotta
    ]
    private let modes = ["Simulation", "Scenario Builder"]

    var body: some View {
        VStack(spacing: 0) {
            productBar
            Divider()
            navigationBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .refractiveCanvas(forceDark: true)
        }
        .frame(minWidth: 1040, minHeight: 720)
        .refractiveCanvas(forceDark: true)
        .tint(Theme.civic)
        #if IVO_PREVIEW
        .onAppear {
            let surface = ProcessInfo.processInfo.environment["IVO_PREVIEW_SURFACE"]?.lowercased() ?? ""
            if surface.contains("scenario-builder") {
                model.appMode = 1
            } else {
                model.appMode = 0
                if surface.contains("senate") { model.tab = 1 }
                else if surface.contains("house") { model.tab = 2 }
                else if surface.contains("president") { model.tab = 3 }
                else if surface.contains("apportionment") { model.tab = 4 }
                else if surface.contains("redistrict") { model.tab = 5 }
                else if surface.contains("forecast") { model.tab = 6 }
                else { model.tab = 0 }
            }
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if model.appMode == 0 {
            switch model.tab {
            case 0: OverviewView()
            case 1: SenateView()
            case 2: HouseView()
            case 3: PresidentialView()
            case 4: ApportionmentView()
            case 5: RedistrictView()
            default: ForecastView()
            }
        } else {
            ScenarioBuilderView()
        }
    }

    private var productBar: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(LinearGradient(colors: [Color(red: 0.08, green: 0.30, blue: 0.40),
                                                  Color(red: 0.16, green: 0.55, blue: 0.64)],
                                         startPoint: .bottomLeading, endPoint: .topTrailing))
                Image(systemName: "building.columns.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text("Psephos").font(.system(size: 15, weight: .semibold))
                Text("United States election laboratory")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            Picker("Workspace", selection: Binding(get: { model.appMode }, set: { model.appMode = $0 })) {
                ForEach(modes.indices, id: \.self) { index in
                    Text(modes[index]).tag(index)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 270)
            .accessibilityLabel("Psephos workspace")

            Spacer(minLength: 12)

            if model.editCount == 0 {
                StatusPill(title: "Model baseline", symbol: "checkmark.circle.fill", tint: Theme.gain)
            } else {
                StatusPill(
                    title: "\(model.editCount) scenario edit\(model.editCount == 1 ? "" : "s")",
                    symbol: "slider.horizontal.3",
                    tint: Theme.ind
                )
            }

            Button {
                model.reset()
            } label: {
                Label("Reset scenario", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.editCount == 0)
            .help("Restore model, demographic, map, electoral-vote, and forecast defaults")
            .accessibilityHint("Keeps the current workspace and selected screen")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var navigationBar: some View {
        Group {
            if model.appMode == 0 {
                HStack(spacing: 4) {
                        ForEach(tabs.indices, id: \.self) { index in
                            let selected = model.tab == index
                            // No `withAnimation`: a global transaction also animates
                            // the screen the tab swaps in. The `.animation` below
                            // scopes the pill morph to the nav bar instead.
                            Button {
                                model.tab = index
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: icons[index])
                                        .foregroundStyle(selected ? Color.white : tabTints[index])
                                    Text(tabs[index])
                                }
                                .font(.system(size: 10.5, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 27)
                                .background {
                                    // Solid tint, not tinted glass: the glass tint goes
                                    // pale in light appearance and the white label on it
                                    // stops being legible.
                                    if selected {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(tabTints[index])
                                            .matchedGeometryEffect(id: "navPill", in: tabGlass)
                                    }
                                }
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .foregroundStyle(selected ? Color.white : Color.secondary)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 11).fill(Color.primary.opacity(0.055)))
                .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: model.tab)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "cursorarrow.click.2")
                        .foregroundStyle(Theme.civic)
                    Text("Direct contest control")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Set competitive presidential states, Senate seats, and the final House balance.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    StatusPill(title: "Model / D / R", symbol: "switch.2", tint: Theme.civic)
                }
                .frame(minHeight: 29)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .refractiveCanvas(forceDark: true)
    }
}
