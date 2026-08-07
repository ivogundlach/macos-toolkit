import SwiftUI

final class FoodSearchVM: ObservableObject {
    @Published var query = ""
    @Published var results: [FoodHit] = []
    @Published var selected: FoodHit?
    @Published var grams: Double = 100

    var canAdd: Bool { selected != nil && grams.isFinite && grams > 0 }

    func search(using database: FoodDB) {
        results = query.count >= 2 ? database.search(query) : []
        if let selected, !results.contains(where: { $0.fdcId == selected.fdcId }) {
            self.selected = nil
        }
    }
}

struct FoodSearchView: View {
    let day: Date
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = FoodSearchVM()

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()

            VStack(spacing: 10) {
                searchField

                if !store.foodDB.isOpen {
                    HealthNotice(title: "USDA database unavailable",
                                 message: "The bundled food database could not be opened. Quick Add remains available from the Log screen.",
                                 systemImage: "externaldrive.badge.xmark", color: HealthUI.negative)
                }
            }
            .padding(14)

            resultsSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            selectionFooter
        }
        .background(HealthUI.workspace)
    }

    private var sheetHeader: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: HealthUI.controlRadius, style: .continuous)
                    .fill(HealthUI.accentSoft)
                Image(systemName: "magnifyingglass").foregroundStyle(HealthUI.accent)
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Search USDA foods").font(.title2.weight(.semibold))
                Text("Add a measured food entry to \(day.formatted(date: .abbreviated, time: .omitted)).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(HealthSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search by food name, such as beef ground or mussels", text: $vm.query)
                .textFieldStyle(.plain)
                .onChange(of: vm.query) { vm.search(using: store.foodDB) }
            if !vm.query.isEmpty {
                Button {
                    vm.query = ""
                    vm.results = []
                    vm.selected = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear USDA search")
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: HealthUI.controlRadius, style: .continuous)
            .fill(HealthUI.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: HealthUI.controlRadius, style: .continuous)
            .strokeBorder(HealthUI.hairline, lineWidth: 1))
    }

    @ViewBuilder
    private var resultsSurface: some View {
        if vm.query.count < 2 {
            HealthEmptyState(title: "Search the bundled catalog",
                             message: "Enter at least two characters. Results include SR Legacy and Foundation foods.",
                             systemImage: "text.magnifyingglass")
        } else if vm.results.isEmpty {
            HealthEmptyState(title: "No matching foods",
                             message: "Try fewer words or a more general food name.",
                             systemImage: "magnifyingglass")
        } else {
            List(vm.results, selection: Binding(
                get: { vm.selected?.fdcId },
                set: { id in vm.selected = vm.results.first { $0.fdcId == id } }
            )) { hit in
                HStack(spacing: 10) {
                    Image(systemName: hit.isFoundation ? "leaf.fill" : "books.vertical.fill")
                        .foregroundStyle(hit.isFoundation ? HealthUI.accent : .secondary)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.description).lineLimit(2).font(.callout.weight(.medium))
                        Text(hit.isFoundation ? "Foundation Foods" : "SR Legacy")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .tag(hit.fdcId)
                .contentShape(Rectangle())
                .onTapGesture { vm.selected = hit }
                .accessibilityElement(children: .combine)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private var selectionFooter: some View {
        HStack(spacing: 12) {
            if let selected = vm.selected {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Selected food").font(.caption2).foregroundStyle(.secondary)
                    Text(selected.description).font(.callout.weight(.medium)).lineLimit(1)
                }
                Spacer(minLength: 8)
                TextField("Grams", value: $vm.grams, format: .number)
                    .frame(width: 76)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("Gram amount")
                Text("g").font(.callout).foregroundStyle(.secondary)
                Button {
                    store.logUSDA(selected, grams: vm.grams, on: day)
                    dismiss()
                } label: {
                    Label("Add food", systemImage: "plus")
                }
                .buttonStyle(HealthPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!vm.canAdd)
                .help(vm.canAdd ? "Add the selected gram amount." : "Enter a gram amount greater than zero.")
            } else {
                Label("Select a result to choose its gram amount.", systemImage: "cursorarrow.click")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(14)
        .background(HealthUI.groupedSurface)
    }
}
