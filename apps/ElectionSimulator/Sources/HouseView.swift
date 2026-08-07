import SwiftUI

struct HouseView: View {
    private var model: AppModel { AppModel.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(
                    eyebrow: "Demographic model",
                    title: "House popular vote and seats",
                    detail: "Build a national two-party vote from electorate composition, turnout, and party support, then translate that vote to a 435-seat chamber.",
                    symbol: "person.3"
                )

                resultCard

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    supportCard
                    turnoutCard
                }

                compositionCard
                methodologyCard
            }
            .padding(16)
        }
    }

    private var resultCard: some View {
        let house = model.house
        let democraticControl = house.demSeats >= 218
        let direct = model.scenario.houseOverrideDemSeats != nil

        return Card(
            title: "Modeled House result",
            subtitle: direct ? "Vote share remains modeled; seat control is directly overridden in Scenario Builder." : "Two-party Democratic share translated through the calibrated uniform-swing curve.",
            symbol: "chart.bar.fill",
            tint: democraticControl ? Theme.dem : Theme.rep
        ) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 10) {
                    ResultTile(
                        title: "Democratic two-party vote",
                        value: String(format: "%.1f%%", house.nationalDem2p * 100),
                        detail: plusMinus((house.nationalDem2p - 0.5) * 100),
                        symbol: "percent",
                        tint: house.nationalDem2p >= 0.5 ? Theme.dem : Theme.rep
                    )
                    ResultTile(
                        title: direct ? "Direct seat outcome" : "Projected seats",
                        value: "D \(house.demSeats) · R \(house.repSeats)",
                        detail: democraticControl ? "Democratic majority" : "Republican majority",
                        symbol: direct ? "hand.point.up.left.fill" : "building.columns.fill",
                        tint: democraticControl ? Theme.dem : Theme.rep
                    )
                }
                CompositionBar(dem: house.demSeats, rep: house.repSeats, total: 435, majorityAt: 218, height: 25)
            }
        }
    }

    private var supportCard: some View {
        Card(
            title: "Democratic support",
            subtitle: "Two-party Democratic share within each voting group.",
            symbol: "person.2.wave.2",
            tint: Theme.dem
        ) {
            VStack(spacing: 7) {
                ForEach(Static.groups) { group in
                    SliderRow(
                        label: group.label,
                        value: model.supportBinding(group.key),
                        range: 0...1,
                        step: 0.01,
                        format: { String(format: "%.0f%% D", $0 * 100) },
                        accent: Theme.dem,
                        width: 120
                    )
                }
            }
        }
    }

    private var turnoutCard: some View {
        Card(
            title: "Eligible-voter turnout",
            subtitle: "Share of each group's eligible voters who cast a ballot.",
            symbol: "checkmark.square",
            tint: Theme.ind
        ) {
            VStack(spacing: 7) {
                ForEach(Static.groups) { group in
                    SliderRow(
                        label: group.label,
                        value: model.turnoutBinding(group.key),
                        range: 0...1,
                        step: 0.01,
                        format: { String(format: "%.0f%%", $0 * 100) },
                        accent: Theme.ind,
                        width: 120
                    )
                }
            }
        }
    }

    private var compositionCard: some View {
        let house = model.house
        return Card(
            title: "Electorate composition",
            subtitle: "Project the electorate forward. Each bar shows a group's share of actual voters; the D/R badge shows its modeled lean.",
            symbol: "person.3.sequence.fill",
            tint: Theme.gain
        ) {
            VStack(alignment: .leading, spacing: 10) {
                SliderRow(
                    label: "Projection year",
                    value: model.projYearBinding,
                    range: 2024...2040,
                    step: 2,
                    format: { String(Int($0)) },
                    accent: Theme.gain,
                    width: 120
                )
                Divider()
                ForEach(house.contributions) { contribution in
                    HStack(spacing: 10) {
                        Text(contribution.label)
                            .font(.system(size: 10, weight: .medium))
                            .frame(width: 150, alignment: .leading)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 5).fill(Theme.panelStrong)
                                RoundedRectangle(cornerRadius: 5)
                                    .fill((contribution.support >= 0.5 ? Theme.dem : Theme.rep).opacity(0.78))
                                    .frame(width: max(2, geometry.size.width * contribution.compShare))
                            }
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border, lineWidth: 1))
                        }
                        .frame(height: 16)
                        Text(String(format: "%.0f%% voters", contribution.compShare * 100))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 82, alignment: .trailing)
                        StatusPill(
                            title: contribution.support >= 0.5 ? "D" : "R",
                            symbol: contribution.support >= 0.5 ? "d.circle.fill" : "r.circle.fill",
                            tint: contribution.support >= 0.5 ? Theme.dem : Theme.rep
                        )
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(contribution.label), \(Int((contribution.compShare * 100).rounded())) percent of voters, \(contribution.support >= 0.5 ? "Democratic" : "Republican") leaning")
                }
            }
        }
    }

    private var methodologyCard: some View {
        Card(
            title: "Model method",
            subtitle: "Transparent inputs, no hidden candidate adjustment",
            symbol: "function",
            tint: Theme.civic
        ) {
            Text("Democratic share = Σ(composition × turnout × support) ÷ Σ(composition × turnout). Seats use a uniform-swing curve with responsiveness \(String(format: "%.1f", Static.seatsVotes.swingRatio)), calibrated to the 2024 House result. Baseline inputs come from ACS, CPS, and validated-voter estimates.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
