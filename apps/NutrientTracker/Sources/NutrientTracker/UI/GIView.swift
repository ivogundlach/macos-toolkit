import SwiftUI

final class GIVM: ObservableObject {
    @Published var kinds: Set<String> = []
    @Published var severity: Double = 3
    @Published var note = ""
    @Published var date: Date = .now
    @Published var confirmation: String?

    func resetForm() {
        kinds = []
        severity = 3
        note = ""
        date = .now
    }
}

struct GIView: View {
    @EnvironmentObject var store: Store
    @StateObject private var vm = GIVM()

    private var recent: [SymptomEntry] {
        store.symptoms.sorted { $0.date > $1.date }
    }
    private var correlations: [FoodSymptomStat] { store.correlations() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HealthUI.regionSpacing) {
                HealthPageHeader(
                    eyebrow: "Digestive patterns",
                    title: "GI Tracking",
                    summary: "Record an episode once, then let repeated timing reveal possible food associations.",
                    systemImage: "waveform.path.ecg",
                    tint: AppSection.gi.tint
                ) {
                    HStack(spacing: 7) {
                        HealthStatusPill(text: "\(store.symptoms.count) episodes",
                                         systemImage: "list.bullet", color: HealthUI.gi)
                        HealthStatusPill(text: "\(correlations.count) associations",
                                         systemImage: "link", color: HealthUI.accent)
                    }
                }

                HealthPanel(
                    title: "Log an episode",
                    subtitle: "Select every symptom present. Severity runs from 1 (very mild) to 5 (severe).",
                    systemImage: "plus.circle"
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        HealthSectionLabel(text: "Symptoms")
                        FlowChips(options: SymptomKind.all, selection: $vm.kinds)

                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text("Severity").font(.callout.weight(.medium))
                                Spacer()
                                HealthStatusPill(text: "\(Int(vm.severity)) of 5 · \(severityLabel(Int(vm.severity)))",
                                                 systemImage: severityIcon(Int(vm.severity)),
                                                 color: severityColor(Int(vm.severity)))
                            }
                            Slider(value: $vm.severity, in: 1...5, step: 1)
                                .tint(severityColor(Int(vm.severity)))
                                .accessibilityLabel("Symptom severity")
                                .accessibilityValue("\(Int(vm.severity)) of 5, \(severityLabel(Int(vm.severity)))")
                        }

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                DatePicker("Date and time", selection: $vm.date)
                                TextField("Optional context or note", text: $vm.note)
                                    .textFieldStyle(.roundedBorder)
                            }
                            VStack(alignment: .leading, spacing: 9) {
                                DatePicker("Date and time", selection: $vm.date)
                                TextField("Optional context or note", text: $vm.note)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                        HStack(spacing: 10) {
                            Button {
                                store.addSymptom(SymptomEntry(
                                    date: vm.date,
                                    kinds: vm.kinds.sorted(),
                                    severity: Int(vm.severity),
                                    note: vm.note.trimmingCharacters(in: .whitespacesAndNewlines)
                                ))
                                vm.resetForm()
                                vm.confirmation = "Episode added to your timeline."
                            } label: {
                                Label("Add episode", systemImage: "plus")
                            }
                            .buttonStyle(HealthPrimaryButtonStyle())
                            .keyboardShortcut(.defaultAction)
                            .disabled(vm.kinds.isEmpty)
                            .help(vm.kinds.isEmpty ? "Select at least one symptom first." : "Add this GI episode.")

                            if vm.kinds.isEmpty {
                                Text("Select at least one symptom")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if let confirmation = vm.confirmation {
                                Label(confirmation, systemImage: "checkmark.circle.fill")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(HealthUI.positive)
                            }
                        }
                    }
                }

                HealthPanel(
                    title: "Possible food associations",
                    subtitle: "A food counts when it was eaten within \(Int(store.profile.correlationWindowHours)) hours before an episode. Association is not proof.",
                    systemImage: "point.3.connected.trianglepath.dotted"
                ) {
                    if correlations.isEmpty {
                        HealthEmptyState(title: "No associations yet",
                                         message: "Log foods and several symptom episodes before drawing a pattern.",
                                         systemImage: "link.badge.plus")
                    } else {
                        VStack(spacing: 8) {
                            ForEach(correlations) { correlationRow($0) }
                        }
                    }
                }

                HealthPanel(
                    title: "Recent episodes",
                    subtitle: "The newest 40 entries are shown. Deleting an episode immediately updates correlations.",
                    systemImage: "clock.arrow.circlepath"
                ) {
                    if recent.isEmpty {
                        HealthEmptyState(title: "No GI episodes logged",
                                         message: "Use the form above when you have something worth tracking.",
                                         systemImage: "waveform.path.ecg")
                    } else {
                        VStack(spacing: 7) {
                            ForEach(recent.prefix(40)) { symptomRow($0) }
                        }
                    }
                }
            }
            .padding(HealthUI.pageInset)
        }
        .navigationTitle("GI Tracking")
        .background(HealthUI.workspace)
    }

    private func correlationRow(_ correlation: FoodSymptomStat) -> some View {
        let state = associationState(correlation.rate)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: state.icon)
                    .foregroundStyle(state.color)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(correlation.food).font(.callout.weight(.semibold))
                    if !correlation.topSymptoms.isEmpty {
                        Text(correlation.topSymptoms.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                HealthStatusPill(text: state.label, systemImage: state.icon, color: state.color)
            }
            GapBar(pct: correlation.rate, tint: state.color,
                   accessibilityName: "\(correlation.food) symptom association rate")
            HStack {
                Text("\(correlation.followed) of \(correlation.eaten) logged exposures were followed by symptoms")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(correlation.rate * 100))%")
                    .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(state.color)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: HealthUI.rowRadius, style: .continuous)
            .fill(HealthUI.groupedSurface))
        .accessibilityElement(children: .combine)
    }

    private func symptomRow(_ symptom: SymptomEntry) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(severityColor(symptom.severity).opacity(0.12))
                Image(systemName: severityIcon(symptom.severity))
                    .foregroundStyle(severityColor(symptom.severity))
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(symptom.kinds.joined(separator: " · "))
                    .font(.callout.weight(.medium))
                HStack(spacing: 6) {
                    Text(severityLabel(symptom.severity).capitalized)
                    if !symptom.note.isEmpty {
                        Text("· \(symptom.note)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(symptom.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Button(role: .destructive) { store.remove(symptom) } label: {
                Image(systemName: "trash")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete \(symptom.kinds.joined(separator: ", ")) episode")
            .help("Delete this GI episode")
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: HealthUI.rowRadius, style: .continuous)
            .fill(HealthUI.groupedSurface))
    }

    private func associationState(_ rate: Double) -> (label: String, icon: String, color: Color) {
        if rate >= 0.5 { return ("Frequent", "exclamationmark.triangle.fill", HealthUI.negative) }
        if rate >= 0.25 { return ("Watch", "eye.fill", HealthUI.warning) }
        return ("Low signal", "minus.circle", .secondary)
    }

    private func severityLabel(_ severity: Int) -> String {
        ["", "very mild", "mild", "moderate", "strong", "severe"][min(max(severity, 0), 5)]
    }

    private func severityIcon(_ severity: Int) -> String {
        if severity >= 5 { return "exclamationmark.octagon.fill" }
        if severity >= 3 { return "exclamationmark.triangle.fill" }
        return "circle.lefthalf.filled"
    }

    private func severityColor(_ severity: Int) -> Color {
        if severity >= 5 { return HealthUI.negative }
        if severity >= 3 { return HealthUI.warning }
        return HealthUI.gi
    }
}

/// Wrapping, multi-select symptom controls. A checkmark and explicit selected
/// accessibility value make selection independent of tint.
struct FlowChips: View {
    let options: [String]
    @Binding var selection: Set<String>
    private let columns = [GridItem(.adaptive(minimum: 128), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(options, id: \.self) { option in
                let selected = selection.contains(option)
                Button {
                    if selected { selection.remove(option) } else { selection.insert(option) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: selected ? "checkmark.square.fill" : "square")
                            .accessibilityHidden(true)
                        Text(option).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(selected ? HealthUI.accent : Color.primary)
                    .background(RoundedRectangle(cornerRadius: HealthUI.controlRadius, style: .continuous)
                        .fill(selected ? HealthUI.accentSoft : HealthUI.groupedSurface))
                    .overlay(RoundedRectangle(cornerRadius: HealthUI.controlRadius, style: .continuous)
                        .strokeBorder(selected ? HealthUI.accent.opacity(0.55) : HealthUI.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option)
                .accessibilityValue(selected ? "Selected" : "Not selected")
            }
        }
    }
}
