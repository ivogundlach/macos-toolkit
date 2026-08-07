import SwiftUI

struct GapsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState

    private var gaps: [GapResult] { store.gaps(on: app.selectedDay) }
    private var watches: [WatchResult] { store.watches(on: app.selectedDay) }
    private var dayItems: [LoggedItem] { Engine.items(store.items, on: app.selectedDay) }

    var body: some View {
        let lowCount = gaps.filter { $0.remaining > 0 }.count
        let metCount = gaps.count - lowCount
        let overCount = watches.filter(\.overLimit).count

        ScrollView {
            VStack(alignment: .leading, spacing: HealthUI.regionSpacing) {
                HealthPageHeader(
                    eyebrow: "Daily drill-down",
                    title: "Day Detail",
                    summary: "Inspect one day's entries and coverage without confusing a snapshot for your habit.",
                    systemImage: "chart.bar.doc.horizontal",
                    tint: AppSection.gaps.tint
                ) {
                    DatePicker("Day", selection: $app.selectedDay, displayedComponents: .date)
                        .datePickerStyle(.field)
                        .fixedSize()
                        .accessibilityLabel("Day detail date")
                }

                HealthNotice(
                    title: "A single day is context, not a grade",
                    message: "Use Long-term Health for decisions. This screen exists to audit a particular day's inputs and explain its coverage bars.",
                    systemImage: "calendar.badge.exclamationmark"
                )

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 10)], spacing: 10) {
                    HealthMetric(label: "Logged items", value: "\(dayItems.count)",
                                 detail: app.selectedDay.formatted(date: .abbreviated, time: .omitted),
                                 systemImage: "list.bullet.rectangle")
                    HealthMetric(label: "Below target", value: "\(lowCount)",
                                 detail: "daily gaps, not habitual gaps",
                                 systemImage: "arrow.down.circle", color: lowCount == 0 ? HealthUI.positive : HealthUI.warning)
                    HealthMetric(label: "Target met", value: "\(metCount)",
                                 detail: "nutrients at or above target",
                                 systemImage: "checkmark.circle", color: HealthUI.positive)
                    HealthMetric(label: "Over limit", value: "\(overCount)",
                                 detail: "upper-limit flags for this day",
                                 systemImage: "exclamationmark.octagon", color: overCount == 0 ? HealthUI.positive : HealthUI.negative)
                }

                if dayItems.isEmpty {
                    HealthNotice(title: "Nothing logged for this day",
                                 message: "Coverage is shown as zero because there are no entries to inspect. Add entries from Log if this was a tracked day.",
                                 systemImage: "square.and.pencil", color: HealthUI.warning)
                }

                HealthPanel(
                    title: "Micronutrient coverage",
                    subtitle: "Daily total against the current target. Documented deficiency magnitude is shown where available.",
                    systemImage: "scope"
                ) {
                    VStack(spacing: 8) {
                        ForEach(gaps) { gapRow($0) }
                    }
                }

                HealthPanel(
                    title: "Saturation and upper limits",
                    subtitle: "Nutrients already abundant in the diet, or worth watching before adding more supplements.",
                    systemImage: "shield.lefthalf.filled"
                ) {
                    VStack(spacing: 8) {
                        ForEach(watches) { watchRow($0) }
                    }
                }
            }
            .padding(HealthUI.pageInset)
        }
        .navigationTitle("Day Detail")
        .background(HealthUI.workspace)
    }

    private func gapRow(_ gap: GapResult) -> some View {
        let met = gap.remaining <= 0
        let color = met ? HealthUI.positive : (gap.pct >= 0.7 ? HealthUI.warning : HealthUI.negative)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: met ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(color).frame(width: 17).accessibilityHidden(true)
                Text(gap.def.name).font(.callout.weight(.semibold))
                MagnitudeTag(text: gap.def.docMagnitude)
                Spacer(minLength: 8)
                Text("\(fmt(gap.total, gap.def.unit)) / \(fmt(gap.target, gap.def.unit))")
                    .font(.callout).monospacedDigit()
            }
            GapBar(pct: gap.pct, tint: color,
                   accessibilityName: "\(gap.def.name) coverage on selected day")
            HStack {
                Label(met ? "Target met" : "Need \(fmt(gap.remaining, gap.def.unit)) more",
                      systemImage: met ? "checkmark" : "minus")
                    .font(.caption.weight(.medium)).foregroundStyle(color)
                Spacer()
                if let documented = gap.def.docMissing {
                    Text("Documented gap: \(documented)")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: HealthUI.rowRadius, style: .continuous)
            .fill(HealthUI.groupedSurface))
        .accessibilityElement(children: .combine)
    }

    private func watchRow(_ watch: WatchResult) -> some View {
        let color = watch.overLimit ? HealthUI.negative : HealthUI.positive
        let status = watch.overLimit ? "Over limit" : (watch.def.upperLimit == nil ? "No established limit" : "Within limit")
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: watch.overLimit ? "xmark.octagon.fill" : "checkmark.shield.fill")
                    .foregroundStyle(color).frame(width: 17).accessibilityHidden(true)
                Text(watch.def.name).font(.callout.weight(.semibold))
                Spacer()
                Text(fmt(watch.total, watch.def.unit)).font(.callout).monospacedDigit()
                HealthStatusPill(text: status,
                                 systemImage: watch.overLimit ? "xmark" : "checkmark",
                                 color: watch.def.upperLimit == nil ? .secondary : color)
            }
            if let note = watch.def.note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: HealthUI.rowRadius, style: .continuous)
            .fill(HealthUI.groupedSurface))
        .accessibilityElement(children: .combine)
    }
}
