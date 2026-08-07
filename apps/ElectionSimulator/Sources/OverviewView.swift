import SwiftUI

struct OverviewView: View {
    private var model: AppModel { AppModel.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(
                    eyebrow: "Current scenario",
                    title: "Election control center",
                    detail: "One live view of chamber control, the presidential map, and the next reapportionment. Every result follows the same scenario used by Forecast and Scenario Builder.",
                    symbol: "square.grid.2x2"
                )

                scenarioStrip

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 12
                ) {
                    senateCard
                    houseCard
                    presidentialCard
                }

                apportionmentCard
            }
            .padding(16)
        }
    }

    private var scenarioStrip: some View {
        HStack(spacing: 7) {
            StatusPill(title: "Senate target 2032", symbol: "calendar", tint: Theme.civic)
            StatusPill(title: "House electorate \(model.demo.projYear)", symbol: "person.3", tint: Theme.civic)
            StatusPill(
                title: model.scenario.evBasis2030 ? "2030 EV basis" : "Current EV basis",
                symbol: "map",
                tint: Theme.civic
            )
            StatusPill(
                title: "\(model.scenario.splitStates.count) split state\(model.scenario.splitStates.count == 1 ? "" : "s")",
                symbol: "arrow.triangle.branch",
                tint: Theme.ind
            )
            Spacer(minLength: 0)
        }
    }

    private var senateCard: some View {
        let target = model.senate.results.first { $0.cycle.year == 2032 }?.composition ?? model.senate.baseline
        let majority = target.senateMajority()
        return Card(
            title: "Senate after 2032",
            subtitle: "Five chained cycles from today's chamber",
            symbol: "building.columns",
            tint: majority.map(Theme.color) ?? Theme.toss
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TallyChips(comp: target)
                    Spacer()
                    StatusPill(
                        title: majority.map { "\($0.short) majority" } ?? "50–50",
                        symbol: majority == nil ? "equal.circle.fill" : "checkmark.seal.fill",
                        tint: majority.map(Theme.color) ?? Theme.toss
                    )
                }
                CompositionBar(dem: target.demCaucus, rep: target.repCaucus, total: 100, majorityAt: 51)
                Divider()
                trajectory
            }
        }
    }

    private var trajectory: some View {
        HStack(spacing: 0) {
            ForEach(model.senate.results) { result in
                let demControl = result.composition.demCaucus >= 51
                VStack(spacing: 3) {
                    Text(result.cycle.label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("D\(result.composition.demCaucus) · R\(result.composition.repCaucus)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(demControl ? "D" : "R")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(demControl ? Theme.dem : Theme.rep)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var houseCard: some View {
        let house = model.house
        let democraticControl = house.demSeats >= 218
        return Card(
            title: "House",
            subtitle: model.scenario.houseOverrideDemSeats == nil
                ? "Generic ballot from demographic inputs"
                : "Direct seat result from Scenario Builder",
            symbol: "person.3",
            tint: democraticControl ? Theme.dem : Theme.rep
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(String(format: "%.1f%%", house.nationalDem2p * 100))
                            .font(.system(size: 23, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("Democratic two-party share")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("D \(house.demSeats) · R \(house.repSeats)")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text(democraticControl ? "Democratic majority" : "Republican majority")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(democraticControl ? Theme.dem : Theme.rep)
                    }
                }
                CompositionBar(dem: house.demSeats, rep: house.repSeats, total: 435, majorityAt: 218)
                Text("National environment: \(plusMinus((house.nationalDem2p - 0.5) * 100))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var presidentialCard: some View {
        let president = model.president
        let winner = president.winner
        return Card(
            title: "President",
            subtitle: model.scenario.evBasis2030 ? "Projected 2030 apportionment" : "Current apportionment",
            symbol: "flag",
            tint: winner.map(Theme.color) ?? Theme.toss
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("D \(president.demEV)")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.dem)
                    Spacer()
                    StatusPill(
                        title: winner.map { "\($0.short) wins" } ?? "269–269 tie",
                        symbol: winner == nil ? "equal.circle.fill" : "checkmark.seal.fill",
                        tint: winner.map(Theme.color) ?? Theme.toss
                    )
                    Spacer()
                    Text("R \(president.repEV)")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.rep)
                }
                CompositionBar(dem: president.demEV, rep: president.repEV, total: 538, majorityAt: 270)
                HStack {
                    Text("270 electoral votes to win")
                    Spacer()
                    Text("\(model.scenario.presOverride.count) forced states")
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var apportionmentCard: some View {
        let projected = model.projection.seats
        let movers = Static.votingStates.map { state -> (DState, Int) in
            (state, (projected[state.code] ?? state.seats2020) - state.seats2020)
        }
        .filter { $0.1 != 0 }
        .sorted { abs($0.1) > abs($1.1) }

        return Card(
            title: "Projected 2030 reapportionment",
            subtitle: "Huntington–Hill allocation on projected census population",
            symbol: "arrow.left.arrow.right",
            tint: Theme.civic
        ) {
            if movers.isEmpty {
                EmptyState(title: "No projected seat changes", detail: "Every state retains its current House allocation.", symbol: "equal.circle")
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                    ForEach(movers, id: \.0.code) { state, delta in
                        HStack(spacing: 8) {
                            Image(systemName: delta > 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(delta > 0 ? Theme.gain : Theme.loss)
                            Text(state.name).font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text(delta > 0 ? "+\(delta)" : "\(delta)")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panelStrong))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}
