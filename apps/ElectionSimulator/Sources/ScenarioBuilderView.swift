import SwiftUI

struct ScenarioBuilderView: View {
    private var model: AppModel { AppModel.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(
                    eyebrow: "Direct outcomes",
                    title: "Scenario Builder",
                    detail: "Keep safe territory with the model and take explicit control of competitive presidential states, Senate seats, and the final House balance.",
                    symbol: "cursorarrow.click.2"
                )

                summary
                presidentialSwingStates
                senateSwingSeats
                houseSwingSeats
            }
            .padding(16)
        }
    }

    private var summary: some View {
        let president = model.president
        let house = model.house
        let senate = model.senateAfter(2032) ?? model.senate.baseline
        let senateMajority = senate.senateMajority()

        return LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
            spacing: 12
        ) {
            ResultTile(
                title: "President",
                value: "D \(president.demEV) · R \(president.repEV)",
                detail: president.winner == .dem ? "Democratic win" : president.winner == .rep ? "Republican win" : "269–269 tie",
                symbol: "flag",
                tint: president.winner.map { Theme.color($0) } ?? Theme.toss
            )
            ResultTile(
                title: "Senate after 2032",
                value: "D \(senate.demCaucus) · R \(senate.repCaucus)",
                detail: senateMajority == .dem ? "Democratic majority" : senateMajority == .rep ? "Republican majority" : "50–50 chamber",
                symbol: "building.columns",
                tint: senateMajority.map { Theme.color($0) } ?? Theme.toss
            )
            ResultTile(
                title: "House",
                value: "D \(house.demSeats) · R \(house.repSeats)",
                detail: house.demSeats >= 218 ? "Democratic majority" : "Republican majority",
                symbol: "person.3",
                tint: house.demSeats >= 218 ? Theme.dem : Theme.rep
            )
        }
    }

    private var presidentialSwingStates: some View {
        let rows = model.president.states
            .filter { abs($0.demShare - 50) <= 8 || $0.forced }
            .sorted { abs($0.demShare - 50) < abs($1.demShare - 50) }

        return Card(
            title: "Competitive presidential states",
            subtitle: "States within eight points after the current national swing, plus every directly forced state.",
            symbol: "flag.checkered",
            tint: Theme.civic
        ) {
            if rows.isEmpty {
                EmptyState(
                    title: "No competitive states",
                    detail: "No state is within eight points under the current national swing.",
                    symbol: "flag.slash"
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        presidentialRow(row)
                        if index < rows.count - 1 { Divider().opacity(0.5) }
                    }
                }
            }
        }
    }

    private func presidentialRow(_ row: ScenarioEngine.PresState) -> some View {
        let forced = model.scenario.presOverride[row.state.code]
        return HStack(spacing: 10) {
            row.winner.swatch
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.state.name).font(.system(size: 11, weight: .semibold))
                    if row.split {
                        StatusPill(title: "Split EV", symbol: "arrow.triangle.branch", tint: Theme.ind)
                    }
                }
                Text("\(row.ev) EV · \(plusMinus(row.demShare - 50)) · statewide winner")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer()
            PartyChoiceGroup(selection: forced) { party in
                model.setPresOverride(row.state.code, party: party)
            }
        }
        .padding(.vertical, 7)
    }

    private var senateSwingSeats: some View {
        Card(
            title: "Competitive Senate seats",
            subtitle: "Tossup, lean, and likely seats in each chained cycle, plus every directly forced race.",
            symbol: "person.crop.rectangle.stack",
            tint: Theme.civic
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.senate.results) { result in
                    senateCycleBlock(result)
                }
            }
        }
    }

    @ViewBuilder
    private func senateCycleBlock(_ result: CycleResult) -> some View {
        let rows = result.outcomes
            .filter { abs($0.margin) <= 12 || $0.forced }
            .sorted { abs($0.margin) < abs($1.margin) }

        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("\(result.cycle.label) · \(result.cycle.kind)")
                        .font(.system(size: 10, weight: .bold))
                    Spacer()
                    Text("\(rows.count) competitive")
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.grouped))

                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    senateRow(row, year: result.cycle.year)
                    if index < rows.count - 1 { Divider().opacity(0.5) }
                }
            }
        }
    }

    private func senateRow(_ row: SeatOutcome, year: Int) -> some View {
        let forced = model.senateOverride(year: year, seatID: row.seat.id)
        return HStack(spacing: 10) {
            row.winner.swatch
            VStack(alignment: .leading, spacing: 2) {
                Text(Static.name(row.seat.state)).font(.system(size: 11, weight: .semibold))
                Text("\(row.rating.rawValue) · \(plusMinus(row.margin)) · \(senateCandidate(row, .dem)) vs \(senateCandidate(row, .rep))")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer()
            PartyChoiceGroup(selection: forced) { party in
                model.setSenateOverride(year: year, seatID: row.seat.id, party: party)
            }
        }
        .padding(.vertical, 7)
    }

    private func senateCandidate(_ row: SeatOutcome, _ party: Party) -> String {
        row.seat.party == party ? "\(row.seat.holder) (\(party.short))" : "\(party.name) challenger"
    }

    private var houseSwingSeats: some View {
        let baseline = model.houseModel
        let house = model.house
        let forced = model.scenario.houseOverrideDemSeats

        return Card(
            title: "House seat outcome",
            subtitle: "Future district names would be false precision. Set the aggregate chamber result or return to the demographic model.",
            symbol: "person.3.fill",
            tint: forced == nil ? Theme.civic : (house.demSeats >= 218 ? Theme.dem : Theme.rep)
        ) {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    StatusPill(
                        title: forced == nil ? "Model outcome" : "Direct outcome",
                        symbol: forced == nil ? "function" : "hand.point.up.left.fill",
                        tint: forced == nil ? Theme.civic : (house.demSeats >= 218 ? Theme.dem : Theme.rep)
                    )
                    Spacer()
                    Text("Model baseline · D \(baseline.demSeats) · R \(baseline.repSeats)")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                SliderRow(
                    label: "Democratic seats",
                    value: model.houseDirectSeatsBinding,
                    range: 170...265,
                    step: 1,
                    format: { "D \(Int($0.rounded()))" },
                    accent: Theme.dem,
                    width: 125
                )

                HStack(spacing: 7) {
                    presetButton("Use model", symbol: "function", selected: forced == nil, tint: Theme.civic) {
                        model.clearHouseOverride()
                    }
                    presetButton("Bare D majority", symbol: "d.circle.fill", selected: forced == 218, tint: Theme.dem) {
                        model.setHouseOverrideDemSeats(218)
                    }
                    presetButton("Bare R majority", symbol: "r.circle.fill", selected: forced == 217, tint: Theme.rep) {
                        model.setHouseOverrideDemSeats(217)
                    }
                    Spacer()
                }

                CompositionBar(dem: house.demSeats, rep: house.repSeats, total: 435, majorityAt: 218, height: 25)
            }
        }
    }

    private func presetButton(
        _ title: String,
        symbol: String,
        selected: Bool,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: selected ? "checkmark" : symbol)
                .font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
