import SwiftUI
import Charts

final class TrendsVM: ObservableObject {
    @Published var nutrientKey = "calcium"
    @Published var days = 90
}

struct TrendsView: View {
    @EnvironmentObject var store: Store
    @StateObject private var vm = TrendsVM()

    private var definition: NutrientDef {
        Nutrients.byKey[vm.nutrientKey] ?? Nutrients.gaps[0]
    }
    private var coverage: [(date: Date, pct: Double)] {
        Engine.dailyCoverage(store.items, key: definition.key,
                             target: store.target(for: definition), days: vm.days)
    }
    private var symptomSeries: [(date: Date, n: Int)] {
        Engine.symptomCount(store.symptoms, days: vm.days)
    }
    private var loggedDates: Set<Date> {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -(vm.days - 1),
                                  to: calendar.startOfDay(for: .now)) ?? .distantPast
        return Set(store.items.filter { $0.date >= start }
            .map { calendar.startOfDay(for: $0.date) })
    }
    private var averageCoverage: Double {
        let calendar = Calendar.current
        let rows = coverage.filter { loggedDates.contains(calendar.startOfDay(for: $0.date)) }
        return rows.isEmpty ? 0 : rows.map(\.pct).reduce(0, +) / Double(rows.count)
    }
    private var symptomCount: Int { symptomSeries.reduce(0) { $0 + $1.n } }
    private var chartMaximum: Double { max(1.2, min(3, (coverage.map(\.pct).max() ?? 1.2) * 1.08)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HealthUI.regionSpacing) {
                HealthPageHeader(
                    eyebrow: "Patterns",
                    title: "Trends",
                    summary: "Compare nutrient coverage and GI activity without turning one day into a verdict.",
                    systemImage: "chart.xyaxis.line",
                    tint: AppSection.trends.tint
                )

                HealthPanel(title: "View controls", subtitle: "Both charts use the same trailing window.",
                            systemImage: "slider.horizontal.3") {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 14) { nutrientPicker; rangePicker; Spacer(minLength: 0) }
                        VStack(alignment: .leading, spacing: 10) { nutrientPicker; rangePicker }
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                    HealthMetric(label: "Average coverage",
                                 value: "\(Int(averageCoverage * 100))%",
                                 detail: "\(definition.name), logged days only",
                                 systemImage: averageCoverage >= 1 ? "checkmark.circle" : "chart.bar",
                                 color: coverageColor(averageCoverage))
                    HealthMetric(label: "Logged days", value: "\(loggedDates.count)",
                                 detail: "evidence in this \(vm.days)-day window",
                                 systemImage: "calendar.badge.checkmark")
                    HealthMetric(label: "GI episodes", value: "\(symptomCount)",
                                 detail: "recorded in the same window",
                                 systemImage: "waveform.path.ecg", color: HealthUI.gi)
                }

                HealthPanel(
                    title: "\(definition.name) coverage",
                    subtitle: "Each bar is one calendar day; the dashed rule is your current target.",
                    systemImage: "chart.bar.xaxis"
                ) {
                    if loggedDates.isEmpty {
                        HealthEmptyState(title: "No logged days in this range",
                                         message: "Add representative food or supplement entries to reveal a coverage pattern.",
                                         systemImage: "chart.bar")
                    } else {
                        Chart {
                            ForEach(coverage, id: \.date) { row in
                                BarMark(x: .value("Day", row.date, unit: .day),
                                        y: .value("Coverage", row.pct))
                                    .foregroundStyle(HealthUI.accent)
                                    .opacity(row.pct == 0 ? 0.18 : 0.88)
                            }
                            RuleMark(y: .value("Target", 1.0))
                                .foregroundStyle(.secondary)
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
                                .annotation(position: .top, alignment: .trailing) {
                                    Text("Target")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }
                        }
                        .chartYScale(domain: 0...chartMaximum)
                        .chartYAxis { AxisMarks(format: FloatingPointFormatStyle<Double>.Percent()) }
                        .frame(height: 250)
                        .accessibilityLabel("\(definition.name) daily coverage chart")
                        .accessibilityValue("Average \(Int(averageCoverage * 100)) percent across \(loggedDates.count) logged days")
                    }
                }

                HealthPanel(
                    title: "GI activity",
                    subtitle: "Episode count by day in the selected range. Associations live in GI Tracking.",
                    systemImage: "waveform.path.ecg"
                ) {
                    if symptomCount == 0 {
                        HealthEmptyState(title: "No GI episodes in this range",
                                         message: "That can mean a quiet window or simply no symptom logs yet.",
                                         systemImage: "checkmark.circle")
                    } else {
                        Chart {
                            ForEach(symptomSeries, id: \.date) { row in
                                BarMark(x: .value("Day", row.date, unit: .day),
                                        y: .value("Episodes", row.n))
                                    .foregroundStyle(HealthUI.gi)
                            }
                        }
                        .frame(height: 185)
                        .accessibilityLabel("GI episodes by day")
                        .accessibilityValue("\(symptomCount) episodes in \(vm.days) days")
                    }
                }
            }
            .padding(HealthUI.pageInset)
        }
        .navigationTitle("Trends")
        .background(HealthUI.workspace)
    }

    private var nutrientPicker: some View {
        Picker("Nutrient", selection: $vm.nutrientKey) {
            ForEach(Nutrients.gaps) { nutrient in
                Text(nutrient.name).tag(nutrient.key)
            }
        }
        .frame(width: 250)
        .accessibilityLabel("Trend nutrient")
    }

    private var rangePicker: some View {
        Picker("Range", selection: $vm.days) {
            Text("30 days").tag(30)
            Text("90 days").tag(90)
            Text("365 days").tag(365)
        }
        .pickerStyle(.segmented)
        .frame(width: 320)
        .accessibilityLabel("Trend range")
    }

    private func coverageColor(_ percentage: Double) -> Color {
        if percentage >= 1 { return HealthUI.positive }
        if percentage >= 0.7 { return HealthUI.warning }
        return HealthUI.negative
    }
}
