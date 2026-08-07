import SwiftUI

final class SettingsVM: ObservableObject {
    @Published var showResetConfirmation = false
    @Published var confirmation: String?
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @StateObject private var vm = SettingsVM()

    private var correlationWindow: Binding<Double> {
        Binding(
            get: { store.profile.correlationWindowHours },
            set: { store.profile.correlationWindowHours = $0 }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HealthUI.regionSpacing) {
                HealthPageHeader(
                    eyebrow: "Preferences",
                    title: "Settings",
                    summary: "Review the profile behind the model, tune targets, and verify local data sources.",
                    systemImage: "gearshape",
                    tint: AppSection.settings.tint
                ) {
                    HealthStatusPill(text: "Saved locally", systemImage: "checkmark.circle.fill",
                                     color: HealthUI.positive)
                }

                if let confirmation = vm.confirmation {
                    HealthNotice(title: "Settings updated", message: confirmation,
                                 systemImage: "checkmark.circle.fill", color: HealthUI.positive)
                }

                HealthPanel(
                    title: "Profile context",
                    subtitle: "These documented assumptions give the recommendation engine context; they are not a daily scorecard.",
                    systemImage: "person.text.rectangle"
                ) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 215), spacing: 9)], spacing: 9) {
                        profileValue("Bodyweight", "\(Int(store.profile.bodyweightLb)) lb", "scalemass")
                        profileValue("Framework", store.profile.framework, "leaf")
                        profileValue("Goal", store.profile.goal, "scope")
                        profileValue("Training", store.profile.training, "figure.strengthtraining.traditional")
                        profileValue("Meat intake", "\(Int(store.profile.meatKcalLow))–\(Int(store.profile.meatKcalHigh)) kcal/day", "fork.knife")
                        profileValue("Meat ratio", store.profile.meatRatio, "chart.pie")
                    }
                }

                HealthPanel(
                    title: "Reference targets",
                    subtitle: "Habitual averages are compared with these daily-equivalent targets. Valid positive values save immediately.",
                    systemImage: "target"
                ) {
                    VStack(spacing: 7) {
                        ForEach(Nutrients.gaps) { targetRow($0) }
                    }
                    HStack(spacing: 10) {
                        Button(role: .destructive) {
                            vm.showResetConfirmation = true
                        } label: {
                            Label("Reset all targets", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(HealthSecondaryButtonStyle())
                        .help("Restore every target to its built-in default after confirmation.")
                        Spacer()
                        Label("Changes save automatically", systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 3)
                }

                HealthPanel(
                    title: "GI association window",
                    subtitle: "Foods eaten inside this interval before an episode count as possible triggers.",
                    systemImage: "clock.arrow.2.circlepath"
                ) {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text("Look-back interval").font(.callout.weight(.medium))
                            Spacer()
                            HealthStatusPill(text: "\(Int(store.profile.correlationWindowHours)) hours",
                                             systemImage: "clock", color: HealthUI.gi)
                        }
                        Slider(value: correlationWindow, in: 2...48, step: 1,
                               onEditingChanged: { editing in
                            if !editing {
                                store.save()
                                vm.confirmation = "GI association window saved at \(Int(store.profile.correlationWindowHours)) hours."
                            }
                        })
                        .tint(HealthUI.gi)
                        .accessibilityLabel("GI association look-back window")
                        .accessibilityValue("\(Int(store.profile.correlationWindowHours)) hours")
                        HStack {
                            Text("2 h · narrow")
                            Spacer()
                            Text("48 h · broad")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }

                HealthPanel(
                    title: "Data and storage",
                    subtitle: "Both the USDA catalog and your private tracker state remain local to this Mac.",
                    systemImage: "internaldrive"
                ) {
                    VStack(spacing: 8) {
                        storageRow(
                            title: "USDA food catalog",
                            detail: store.foodDB.isOpen
                                ? "SR Legacy and Foundation database is ready for search."
                                : "Bundled database could not be opened; USDA search is unavailable.",
                            state: store.foodDB.isOpen ? "Ready" : "Unavailable",
                            icon: store.foodDB.isOpen ? "checkmark.circle.fill" : "xmark.octagon.fill",
                            color: store.foodDB.isOpen ? HealthUI.positive : HealthUI.negative
                        )
                        storageRow(
                            title: "Private tracker store",
                            detail: "\(store.items.count) food entries and \(store.symptoms.count) GI episodes in Application Support/NutrientTracker/store.json.",
                            state: "Local JSON",
                            icon: "lock.doc.fill",
                            color: HealthUI.accent
                        )
                        storageRow(
                            title: "Persistence",
                            detail: "Logs, target overrides, and the GI window save on this Mac. No account or cloud sync is used.",
                            state: "Auto-save",
                            icon: "arrow.triangle.2.circlepath",
                            color: .secondary
                        )
                    }
                }

                HealthNotice(
                    title: "Personal tracking, not medical advice",
                    message: "This app organizes your documented nutrition protocol and computes intake gaps from USDA food data. Confirm health decisions with appropriate clinical evidence.",
                    systemImage: "cross.case"
                )
            }
            .padding(HealthUI.pageInset)
        }
        .navigationTitle("Settings")
        .background(HealthUI.workspace)
        .confirmationDialog(
            "Reset every nutrient target?",
            isPresented: $vm.showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset to built-in defaults", role: .destructive) {
                store.resetTargets()
                vm.confirmation = "All nutrient targets were restored to their built-in defaults."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all target overrides. Food logs, GI episodes, and the profile are unchanged.")
        }
    }

    private func profileValue(_ label: String, _ value: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(HealthUI.accent)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: HealthUI.rowRadius, style: .continuous)
            .fill(HealthUI.groupedSurface))
        .accessibilityElement(children: .combine)
    }

    private func targetRow(_ nutrient: NutrientDef) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.hexagongrid.fill")
                .foregroundStyle(HealthUI.accent).frame(width: 17).accessibilityHidden(true)
            Text(nutrient.name).font(.callout.weight(.medium))
            MagnitudeTag(text: nutrient.docMagnitude)
            Spacer(minLength: 8)
            TextField("Target", value: Binding(
                get: { store.target(for: nutrient) },
                set: { value in
                    store.setTarget(value, for: nutrient)
                    vm.confirmation = "\(nutrient.name) target saved."
                }), format: .number)
                .frame(width: 88)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel("\(nutrient.name) target")
            Text(nutrient.unit)
                .font(.callout).foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: HealthUI.rowRadius, style: .continuous)
            .fill(HealthUI.groupedSurface))
    }

    private func storageRow(title: String, detail: String, state: String,
                            icon: String, color: Color) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color).frame(width: 19).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HealthStatusPill(text: state, systemImage: icon, color: color)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: HealthUI.rowRadius, style: .continuous)
            .fill(HealthUI.groupedSurface))
        .accessibilityElement(children: .combine)
    }
}
