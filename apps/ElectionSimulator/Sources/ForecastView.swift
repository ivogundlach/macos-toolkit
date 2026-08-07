import SwiftUI

struct ForecastView: View {
    private var model: AppModel { AppModel.shared }

    var body: some View {
        let forecast = model.forecast
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(
                    eyebrow: "Monte Carlo",
                    title: "Forecast ranges",
                    detail: "Run the current scenario through 5,000 deterministic simulations. The uncertainty scale widens national and race-level error while preserving each model's startup-relative calibration.",
                    symbol: "chart.bar.xaxis"
                )

                settingsCard(forecast)

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 12
                ) {
                    senateCard(forecast)
                    presidentialCard(forecast)
                    houseCard(forecast)
                }

                Card(
                    title: "How to read this forecast",
                    subtitle: "Probability is uncertainty around the scenario, not a new scenario input.",
                    symbol: "info.circle",
                    tint: Theme.civic
                ) {
                    Text("Senate simulations chain stochastically through every cycle to the selected target year. Presidential simulations vary the national swing and state outcomes. House simulations vary the modeled national two-party vote unless Scenario Builder directly fixes the seat result. Bar color marks which side controls at that outcome; each card also names the threshold in text.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
    }

    private func settingsCard(_ forecast: MCResult) -> some View {
        Card(
            title: "Forecast settings",
            subtitle: "Changes recompute all three distributions immediately.",
            symbol: "slider.horizontal.3",
            tint: Theme.ind
        ) {
            HStack(spacing: 16) {
                SliderRow(
                    label: "Unified uncertainty (σ)",
                    value: model.uncertaintyBinding,
                    range: 0.5...8,
                    step: 0.5,
                    format: { String(format: "±%.1f", $0) },
                    accent: Theme.ind,
                    width: 145
                )
                Divider().frame(height: 28)
                HStack(spacing: 7) {
                    Text("Senate target")
                        .font(.system(size: 11, weight: .medium))
                    Picker(
                        "Senate target year",
                        selection: Binding(
                            get: { model.selectedSenateCycle },
                            set: { model.selectedSenateCycle = $0 }
                        )
                    ) {
                        ForEach(SIM_CYCLES) { cycle in
                            Text(cycle.label).tag(cycle.year)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 92)
                }
                Spacer()
                StatusPill(title: "\(forecast.sims) simulations", symbol: "dice", tint: Theme.civic)
            }
        }
    }

    private func senateCard(_ forecast: MCResult) -> some View {
        Card(
            title: "Senate · \(forecast.targetYear)",
            subtitle: "Mean \(String(format: "%.1f", forecast.senateMeanDem)) Democratic caucus seats",
            symbol: "building.columns",
            tint: forecast.senatePDem >= forecast.senatePRep ? Theme.dem : Theme.rep
        ) {
            VStack(alignment: .leading, spacing: 11) {
                probabilityRow(forecast.senatePDem, forecast.senatePRep, tie: forecast.senateP5050)
                Divider()
                histogram(forecast.senateHist, threshold: 51, barWidth: 8, label: "Democratic caucus seats · 51 for majority")
            }
        }
    }

    private func presidentialCard(_ forecast: MCResult) -> some View {
        Card(
            title: "President",
            subtitle: "Mean \(Int(forecast.presMeanDemEV.rounded())) Democratic electoral votes",
            symbol: "flag",
            tint: forecast.presPDem >= 0.5 ? Theme.dem : Theme.rep
        ) {
            VStack(alignment: .leading, spacing: 11) {
                probabilityRow(forecast.presPDem, 1 - forecast.presPDem)
                Divider()
                histogram(forecast.presHist, threshold: 270, barWidth: 9, label: "Democratic electoral votes · 270 to win")
            }
        }
    }

    private func houseCard(_ forecast: MCResult) -> some View {
        Card(
            title: "House",
            subtitle: "Mean \(Int(forecast.houseMeanDemSeats.rounded())) Democratic seats",
            symbol: "person.3",
            tint: forecast.housePDem >= 0.5 ? Theme.dem : Theme.rep
        ) {
            VStack(alignment: .leading, spacing: 11) {
                probabilityRow(forecast.housePDem, 1 - forecast.housePDem)
                Divider()
                histogram(forecast.houseHist, threshold: 218, barWidth: 10, label: "Democratic seats · 218 for majority")
            }
        }
    }

    private func probabilityRow(_ democratic: Double, _ republican: Double, tie: Double = 0) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(percent(democratic))
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.dem)
                Text("Democratic")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            Spacer()
            if tie > 0.005 {
                VStack(spacing: 1) {
                    Text(percent(tie))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    Text("50–50")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(percent(republican))
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.rep)
                Text("Republican")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func histogram(
        _ bars: [Outcome2],
        threshold: Int,
        barWidth: CGFloat,
        label: String
    ) -> some View {
        let maximum = max(bars.map(\.count).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 5) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(bars) { bar in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(bar.value >= threshold ? Theme.dem : Theme.rep)
                            .frame(width: barWidth, height: max(2, CGFloat(bar.count) / CGFloat(maximum) * 72))
                            .help("\(bar.value): \(bar.count) simulations")
                            .accessibilityLabel("\(bar.value), \(bar.count) simulations, \(bar.value >= threshold ? "Democratic control" : "Republican control")")
                    }
                }
                .frame(minHeight: 72, alignment: .bottom)
            }
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func percent(_ probability: Double) -> String {
        if probability > 0 && probability < 0.005 { return "<1%" }
        if probability > 0.995 && probability < 1 { return ">99%" }
        return "\(Int((probability * 100).rounded()))%"
    }
}
