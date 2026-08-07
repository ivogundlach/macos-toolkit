import SwiftUI

final class LongTermVM: ObservableObject {
    @Published var days = 90
}

/// Habitual coverage is the product's center of gravity. Values are averages
/// over logged days, so an empty calendar day never masquerades as a deficiency.
struct LongTermView: View {
    @EnvironmentObject var store: Store
    @StateObject private var vm = LongTermVM()

    private var data: (rows: [ChronicRow], loggedDays: Int, windowDays: Int) {
        store.chronic(days: vm.days)
    }
    private var recommendations: [Recommendation] {
        store.chronicRecommendations(days: vm.days)
    }

    var body: some View {
        let snapshot = data
        let floors = snapshot.rows.filter { $0.target != nil }
            .sorted { ($0.floorPct ?? .greatestFiniteMagnitude) < ($1.floorPct ?? .greatestFiniteMagnitude) }
        let ceilings = snapshot.rows.filter { $0.def.upperLimit != nil }
            .sorted { ($0.ceilingPct ?? 0) > ($1.ceilingPct ?? 0) }
        let lowCount = snapshot.loggedDays == 0 ? 0 : floors.filter { ($0.floorPct ?? 0) < 1 }.count
        let onTrackCount = snapshot.loggedDays == 0 ? 0 : floors.count - lowCount
        let riskCount = snapshot.loggedDays == 0 ? 0 : ceilings.filter { ($0.ceilingPct ?? 0) >= 0.8 }.count

        ScrollView {
            VStack(alignment: .leading, spacing: HealthUI.regionSpacing) {
                HealthPageHeader(
                    eyebrow: "Habitual health",
                    title: "Long-term coverage",
                    summary: "See what your routine supplies—not whether one day looked perfect.",
                    systemImage: "calendar.badge.clock",
                    tint: AppSection.longterm.tint
                ) {
                    windowPicker
                }

                HealthPanel {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
                        HealthMetric(label: "Evidence", value: "\(snapshot.loggedDays)",
                                     detail: "logged of \(snapshot.windowDays) days",
                                     systemImage: "calendar.badge.checkmark")
                        HealthMetric(label: "Under target", value: "\(lowCount)",
                                     detail: "habitual gaps to address",
                                     systemImage: "arrow.down.circle", color: lowCount == 0 ? HealthUI.positive : HealthUI.negative)
                        HealthMetric(label: "On track", value: "\(onTrackCount)",
                                     detail: "nutrients meeting target",
                                     systemImage: "checkmark.circle", color: HealthUI.positive)
                        HealthMetric(label: "Ceiling watch", value: "\(riskCount)",
                                     detail: "at or above 80% of limit",
                                     systemImage: "exclamationmark.triangle", color: riskCount == 0 ? HealthUI.positive : HealthUI.warning)
                    }
                }

                if snapshot.loggedDays == 0 {
                    HealthNotice(
                        title: "No evidence in this window",
                        message: "Log food, fixes, and supplements on the days you consume them. Coverage averages only those logged days.",
                        systemImage: "calendar.badge.exclamationmark",
                        color: HealthUI.warning
                    )
                }

                HealthPanel(
                    title: "Target coverage",
                    subtitle: "Average intake per logged day against your personal target. Lowest coverage appears first.",
                    systemImage: "scope"
                ) {
                    VStack(spacing: 8) {
                        ForEach(floors) { row in
                            floorRow(row, loggedDays: snapshot.loggedDays)
                        }
                    }
                }

                HealthPanel(
                    title: "Routine opportunities",
                    subtitle: "Recommendations close chronic shortfalls in the selected window, never just today's plate.",
                    systemImage: "sparkles"
                ) {
                    if recommendations.isEmpty {
                        HealthEmptyState(
                            title: snapshot.loggedDays == 0 ? "Log a few representative days" : "No routine changes suggested",
                            message: snapshot.loggedDays == 0
                                ? "Recommendations appear once the tracker has habitual intake evidence."
                                : "Your current averages do not expose a catalog-supported chronic gap.",
                            systemImage: snapshot.loggedDays == 0 ? "square.and.pencil" : "checkmark.seal"
                        )
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 10)], spacing: 10) {
                            ForEach(recommendations) { recommendationCard($0) }
                        }
                    }
                }

                HealthPanel(
                    title: "Ceiling watch",
                    subtitle: "Habitual intake nearest a tolerable upper limit appears first. Supplemental-only limits are labeled.",
                    systemImage: "exclamationmark.shield"
                ) {
                    VStack(spacing: 8) {
                        ForEach(ceilings) { row in
                            ceilingRow(row, loggedDays: snapshot.loggedDays)
                        }
                    }
                }

                HealthNotice(
                    title: "How this window is calculated",
                    message: "Figures are averages per logged day. Folate, vitamin E, and magnesium ceilings count supplements only. Vitamin A uses RAE as a proxy for preformed retinol; K2 has no established upper limit. This is not medical advice—confirm fat-soluble vitamins and iron with periodic bloodwork.",
                    systemImage: "info.circle"
                )
            }
            .padding(HealthUI.pageInset)
        }
        .navigationTitle("Long-term Health")
        .background(HealthUI.workspace)
    }

    private var windowPicker: some View {
        Picker("Habit window", selection: $vm.days) {
            Text("30 days").tag(30)
            Text("90 days").tag(90)
            Text("365 days").tag(365)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 240)
        .help("Choose the trailing window used for habitual coverage and recommendations.")
        .accessibilityLabel("Habitual coverage window")
    }

    private func floorRow(_ row: ChronicRow, loggedDays: Int) -> some View {
        let pct = row.floorPct ?? 0
        let state = floorState(pct, loggedDays: loggedDays)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: state.icon)
                    .foregroundStyle(state.color)
                    .frame(width: 17)
                    .accessibilityHidden(true)
                Text(row.def.name).font(.callout.weight(.semibold))
                MagnitudeTag(text: row.def.docMagnitude)
                Spacer(minLength: 8)
                Text("\(fmt(row.perLoggedDay, row.def.unit)) / \(fmt(row.target ?? 0, row.def.unit))")
                    .font(.callout)
                    .monospacedDigit()
            }
            GapBar(pct: pct, accessibilityName: "\(row.def.name) target coverage")
            HStack {
                Text(state.text).font(.caption.weight(.medium)).foregroundStyle(state.color)
                Spacer()
                Text("\(Int(max(0, pct) * 100))% of target")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: HealthUI.rowRadius, style: .continuous)
            .fill(HealthUI.groupedSurface))
        .accessibilityElement(children: .combine)
    }

    private func recommendationCard(_ recommendation: Recommendation) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: recommendation.item.kind == .animalFix ? "fish.fill" : "pills.fill")
                    .foregroundStyle(HealthUI.accent)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recommendation.item.name).font(.callout.weight(.semibold))
                    if let dose = recommendation.item.doseLabel {
                        Text(dose).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(recommendation.covers, id: \.def.key) { coverage in
                    Label("\(coverage.def.name): fills \(Int(coverage.fillPct * 100))% of typical shortfall",
                          systemImage: "arrow.up.right.circle")
                        .font(.caption)
                        .foregroundStyle(HealthUI.positive)
                }
            }
            Text(recommendation.item.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(recommendation.warnings) { warning in
                Label("Daily use projects \(warning.def.name) at \(fmt(warning.projected, warning.def.unit)); limit \(fmt(warning.limit, warning.def.unit)).",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(HealthUI.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                store.logCatalog(recommendation.item, on: .now)
            } label: {
                Label("Log for today", systemImage: "plus")
            }
            .buttonStyle(HealthPrimaryButtonStyle())
            .help("Add this serving or dose to today's log.")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: HealthUI.rowRadius, style: .continuous)
            .fill(HealthUI.groupedSurface))
        .overlay(RoundedRectangle(cornerRadius: HealthUI.rowRadius, style: .continuous)
            .strokeBorder(HealthUI.hairline, lineWidth: 1))
    }

    private func ceilingRow(_ row: ChronicRow, loggedDays: Int) -> some View {
        let pct = row.ceilingPct ?? 0
        let state = ceilingState(pct, loggedDays: loggedDays)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: state.icon)
                    .foregroundStyle(state.color)
                    .frame(width: 17)
                    .accessibilityHidden(true)
                Text(row.def.name).font(.callout.weight(.semibold))
                if row.def.ulSupplementalOnly {
                    HealthStatusPill(text: "Supplements only", systemImage: "pills", color: .secondary)
                }
                Spacer(minLength: 8)
                Text("\(fmt(row.ceilingPerLoggedDay, row.def.unit)) / \(fmt(row.def.upperLimit ?? 0, row.def.unit))")
                    .font(.callout).monospacedDigit()
            }
            GapBar(pct: pct, tint: state.color,
                   accessibilityName: "\(row.def.name) upper-limit usage")
            HStack {
                Text(state.text).font(.caption.weight(.medium)).foregroundStyle(state.color)
                Spacer()
                Text("\(Int(max(0, pct) * 100))% of limit")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: HealthUI.rowRadius, style: .continuous)
            .fill(HealthUI.groupedSurface))
        .accessibilityElement(children: .combine)
    }

    private func floorState(_ pct: Double, loggedDays: Int) -> (text: String, icon: String, color: Color) {
        if loggedDays == 0 { return ("No evidence yet", "minus.circle", .secondary) }
        if pct >= 1 { return ("On track", "checkmark.circle.fill", HealthUI.positive) }
        if pct >= 0.7 { return ("Slightly low", "arrow.down.circle", HealthUI.warning) }
        return ("Chronically low", "exclamationmark.circle.fill", HealthUI.negative)
    }

    private func ceilingState(_ pct: Double, loggedDays: Int) -> (text: String, icon: String, color: Color) {
        if loggedDays == 0 { return ("No evidence yet", "minus.circle", .secondary) }
        if pct >= 1 { return ("Over safe ceiling", "xmark.octagon.fill", HealthUI.negative) }
        if pct >= 0.8 { return ("Approaching ceiling", "exclamationmark.triangle.fill", HealthUI.warning) }
        return ("Within range", "checkmark.circle.fill", HealthUI.positive)
    }
}
