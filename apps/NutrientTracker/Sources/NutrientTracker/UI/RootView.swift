import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                brand
                List(selection: $app.section) {
                    Section("Habitual health") {
                        destination(.longterm)
                        destination(.trends)
                        destination(.gi)
                    }
                    Section("Daily tools") {
                        destination(.today)
                        destination(.gaps)
                    }
                    Section("System") {
                        destination(.settings)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)

                sidebarFooter
            }
            .background(HealthUI.sidebar)
            .frame(minWidth: 220)
        } detail: {
            Group {
                switch app.section ?? .longterm {
                case .longterm: LongTermView()
                case .trends: TrendsView()
                case .gi: GIView()
                case .today: TodayView()
                case .gaps: GapsView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(HealthUI.workspace)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(HealthUI.accent)
        #if IVO_PREVIEW
        .onAppear {
            let surface = ProcessInfo.processInfo.environment["IVO_PREVIEW_SURFACE"]?.lowercased() ?? ""
            if surface.contains("trends") { app.section = .trends }
            else if surface.contains("gi-") || surface.contains("gi_") { app.section = .gi }
            else if surface.contains("log-") || surface.contains("today") { app.section = .today }
            else if surface.contains("day-detail") || surface.contains("gaps") { app.section = .gaps }
            else if surface.contains("settings") { app.section = .settings }
            else { app.section = .longterm }
        }
        #endif
    }

    private var brand: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.02, green: 0.32, blue: 0.30),
                                                  Color(red: 0.16, green: 0.60, blue: 0.52)],
                                         startPoint: .bottomLeading, endPoint: .topTrailing))
                Image(systemName: "leaf.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Nutrient Tracker")
                    .font(.system(size: 15, weight: .semibold))
                Text("Habit over snapshots")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private func destination(_ section: AppSection) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .fill(sectionTint(section))
                Image(systemName: section.icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 21, height: 21)
            .accessibilityHidden(true)
            Text(section.rawValue).font(.callout)
        }
        .tag(section)
        .help(sectionHelp(section))
    }

    private func sectionTint(_ section: AppSection) -> Color { section.tint }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
            Label("\(store.items.count) food logs · \(store.symptoms.count) GI logs",
                  systemImage: "internaldrive")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Label("30 / 90 / 365 day method", systemImage: "calendar")
                .font(.caption2)
                .foregroundStyle(HealthUI.accent)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }

    private func sectionHelp(_ section: AppSection) -> String {
        switch section {
        case .longterm: return "Review habitual nutrient coverage and long-term recommendations."
        case .trends: return "Compare nutrient coverage and GI episodes over time."
        case .gi: return "Log symptoms and review food associations."
        case .today: return "Record food, fixes, and supplements for a selected day."
        case .gaps: return "Inspect one day's nutrient coverage without judging the habit."
        case .settings: return "Review profile, edit targets, and check local storage."
        }
    }
}
