import SwiftUI

final class TodayVM: ObservableObject {
    @Published var showFoodSearch = false
    @Published var showQuickAdd = false
}

struct TodayView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @StateObject private var vm = TodayVM()

    private var dayItems: [LoggedItem] {
        Engine.items(store.items, on: app.selectedDay).sorted { $0.date > $1.date }
    }

    var body: some View {
        let foods = dayItems.filter { $0.source == .usda || $0.source == .custom }.count
        let fixes = dayItems.filter { $0.source == .animalFix }.count
        let supplements = dayItems.filter { $0.source == .supplement }.count

        ScrollView {
            VStack(alignment: .leading, spacing: HealthUI.regionSpacing) {
                HealthPageHeader(
                    eyebrow: "Daily entry",
                    title: "Log",
                    summary: "Record what you consumed. Habitual assessment stays in Long-term Health.",
                    systemImage: "square.and.pencil",
                    tint: AppSection.today.tint
                ) {
                    DatePicker("Log day", selection: $app.selectedDay, displayedComponents: .date)
                        .datePickerStyle(.field)
                        .fixedSize()
                        .accessibilityLabel("Log date")
                }

                HealthPanel(title: "Add to this day",
                            subtitle: "Search the bundled USDA catalog or add one of your established fixes and supplements.",
                            systemImage: "plus.circle") {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { addFoodButton; quickAddButton; Spacer(minLength: 0) }
                        VStack(alignment: .leading, spacing: 9) { addFoodButton; quickAddButton }
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    HealthMetric(label: "All entries", value: "\(dayItems.count)",
                                 detail: app.selectedDay.formatted(date: .abbreviated, time: .omitted),
                                 systemImage: "list.bullet.rectangle")
                    HealthMetric(label: "USDA foods", value: "\(foods)",
                                 detail: "measured food entries", systemImage: "fork.knife")
                    HealthMetric(label: "Food fixes", value: "\(fixes)",
                                 detail: "catalog routine entries", systemImage: "fish.fill")
                    HealthMetric(label: "Supplements", value: "\(supplements)",
                                 detail: "catalog dose entries", systemImage: "pills.fill")
                }

                HealthPanel(
                    title: "Logged items",
                    subtitle: "Entries are snapshotted at log time so historical nutrient totals remain stable.",
                    systemImage: "list.bullet"
                ) {
                    if dayItems.isEmpty {
                        HealthEmptyState(title: "Nothing logged for this day",
                                         message: "Use USDA search for food or Quick Add for your existing routine.",
                                         systemImage: "square.and.pencil")
                    } else {
                        VStack(spacing: 7) {
                            ForEach(dayItems) { loggedRow($0) }
                        }
                    }
                }
            }
            .padding(HealthUI.pageInset)
        }
        .navigationTitle("Log")
        .background(HealthUI.workspace)
        .sheet(isPresented: $vm.showFoodSearch) {
            FoodSearchView(day: app.selectedDay)
                .environmentObject(store)
                .frame(minWidth: 600, minHeight: 500)
        }
        .sheet(isPresented: $vm.showQuickAdd) {
            QuickAddView(day: app.selectedDay)
                .environmentObject(store)
                .frame(minWidth: 520, minHeight: 560)
        }
    }

    private var addFoodButton: some View {
        Button { vm.showFoodSearch = true } label: {
            Label("Search USDA foods", systemImage: "magnifyingglass")
        }
        .buttonStyle(HealthPrimaryButtonStyle())
        .help("Search the bundled USDA food database and choose a gram amount.")
    }

    private var quickAddButton: some View {
        Button { vm.showQuickAdd = true } label: {
            Label("Quick Add routine", systemImage: "pills")
        }
        .buttonStyle(HealthSecondaryButtonStyle())
        .help("Add an established animal-based fix or supplement dose.")
    }

    private func loggedRow(_ item: LoggedItem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(sourceColor(item.source).opacity(0.12))
                Image(systemName: sourceIcon(item.source))
                    .foregroundStyle(sourceColor(item.source))
            }
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.callout.weight(.medium))
                HStack(spacing: 6) {
                    Text(sourceName(item.source))
                    let details = subtitle(item)
                    if !details.isEmpty { Text("· \(details)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(item.date, style: .time)
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Button(role: .destructive) { store.remove(item) } label: {
                Image(systemName: "trash").frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete \(item.name) from log")
            .help("Delete this logged item")
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: HealthUI.rowRadius, style: .continuous)
            .fill(HealthUI.groupedSurface))
        .accessibilityElement(children: .contain)
    }

    private func sourceIcon(_ source: LoggedItem.Source) -> String {
        switch source {
        case .usda, .custom: return "fork.knife"
        case .animalFix: return "fish.fill"
        case .supplement: return "pills.fill"
        }
    }

    private func sourceName(_ source: LoggedItem.Source) -> String {
        switch source {
        case .usda: return "USDA food"
        case .custom: return "Custom food"
        case .animalFix: return "Food fix"
        case .supplement: return "Supplement"
        }
    }

    private func sourceColor(_ source: LoggedItem.Source) -> Color {
        switch source {
        case .usda, .custom, .animalFix: return HealthUI.accent
        case .supplement: return HealthUI.gi
        }
    }

    private func subtitle(_ item: LoggedItem) -> String {
        var parts: [String] = []
        if let grams = item.grams { parts.append("\(Int(grams)) g") }
        if let calories = item.nutrients["kcal"], calories > 0 { parts.append(fmt(calories, "kcal")) }
        return parts.joined(separator: " · ")
    }
}

struct QuickAddView: View {
    let day: Date
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: HealthUI.controlRadius, style: .continuous)
                        .fill(HealthUI.accentSoft)
                    Image(systemName: "bolt.fill").foregroundStyle(HealthUI.accent)
                }
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quick Add").font(.title2.weight(.semibold))
                    Text("Add one established serving to \(day.formatted(date: .abbreviated, time: .omitted)).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(HealthSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    quickSection(title: "Animal-based fixes", icon: "fish.fill",
                                 items: store.catalog.filter { $0.kind == .animalFix })
                    quickSection(title: "Supplements", icon: "pills.fill",
                                 items: store.catalog.filter { $0.kind == .supplement })
                }
                .padding(16)
            }
        }
        .background(HealthUI.workspace)
    }

    private func quickSection(title: String, icon: String, items: [CatalogItem]) -> some View {
        HealthPanel(title: title, subtitle: "Choose one row to log its configured serving or dose.",
                    systemImage: icon) {
            VStack(spacing: 7) {
                ForEach(items) { item in quickRow(item) }
            }
        }
    }

    private func quickRow(_ item: CatalogItem) -> some View {
        Button {
            store.logCatalog(item, on: day)
            dismiss()
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(item.name).font(.callout.weight(.semibold))
                        if let dose = item.doseLabel {
                            HealthStatusPill(text: dose, systemImage: "scalemass", color: .secondary)
                        }
                    }
                    Text(item.detail)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Label("Add", systemImage: "plus")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(HealthUI.accent)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: HealthUI.rowRadius, style: .continuous)
                .fill(HealthUI.groupedSurface))
            .overlay(RoundedRectangle(cornerRadius: HealthUI.rowRadius, style: .continuous)
                .strokeBorder(HealthUI.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: HealthUI.rowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add \(item.name), \(item.doseLabel ?? "configured serving")")
    }
}
