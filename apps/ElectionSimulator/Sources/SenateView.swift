import SwiftUI

struct SenateView: View {
    private var model: AppModel { AppModel.shared }
    private var selected: Int { model.selectedSenateCycle }

    var body: some View {
        HSplitView {
            timeline
                .frame(minWidth: 355, idealWidth: 390)
            cycleDetail
                .frame(minWidth: 540)
        }
    }

    private var timeline: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PageHeader(
                    eyebrow: "Chamber path",
                    title: "Senate trajectory",
                    detail: "Each election changes the starting point for the next cycle. Select a cycle to inspect and override its seats.",
                    symbol: "building.columns"
                )

                compositionRow("Today", model.senate.baseline, year: nil, kind: "Current chamber")
                ForEach(model.senate.results) { result in
                    compositionRow(
                        result.cycle.label,
                        result.composition,
                        year: result.cycle.year,
                        kind: "\(result.cycle.kind) · Class \(roman(result.cycle.senateClass))"
                    )
                }
            }
            .padding(16)
        }
        .refractiveCanvas(forceDark: true)
    }

    private func compositionRow(
        _ title: String,
        _ composition: Composition,
        year: Int?,
        kind: String
    ) -> some View {
        let isSelected = year == selected
        let majority = composition.senateMajority()
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(kind).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(
                    title: majority.map { "\($0.short) majority" } ?? "50–50",
                    symbol: majority == nil ? "equal.circle.fill" : "checkmark.seal.fill",
                    tint: majority.map { Theme.color($0) } ?? Theme.toss
                )
            }

            CompositionBar(
                dem: composition.demCaucus,
                rep: composition.repCaucus,
                total: 100,
                majorityAt: 51,
                height: 20
            )

            HStack {
                TallyChips(comp: composition)
                Spacer()
                if let year {
                    Button {
                        model.selectedSenateCycle = year
                    } label: {
                        Label(isSelected ? "Editing" : "Edit cycle", systemImage: isSelected ? "checkmark.circle.fill" : "arrow.right.circle")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(isSelected ? Theme.civic : Color.secondary)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .padding(11)
        .refractiveGlass(cornerRadius: 11)
        // Selection is an area wash, not a stroke: hairlines wash out against the
        // material's own rim, and a solid wash stays legible in both appearances.
        .overlay(RoundedRectangle(cornerRadius: 11)
            .fill(isSelected ? Theme.civic.opacity(0.16) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .strokeBorder(isSelected ? Theme.civic.opacity(0.42) : Color.clear, lineWidth: 1.5))
    }

    private var cycleDetail: some View {
        let cycle = SIM_CYCLES.first { $0.year == selected } ?? SIM_CYCLES[0]
        let result = model.senate.results.first { $0.cycle.year == selected }
        let overrideCount = model.scenario.senateOverride[cycle.year]?.count ?? 0

        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(
                    eyebrow: "Selected cycle",
                    title: "\(cycle.label) Senate",
                    detail: "Class \(roman(cycle.senateClass)) · \(Static.seats(inClass: cycle.senateClass).count) seats up · \(cycle.kind) electorate",
                    symbol: "calendar.badge.clock"
                )

                HStack(spacing: 7) {
                    StatusPill(title: cycle.kind, symbol: cycle.isPresidential ? "flag.fill" : "person.2.fill", tint: Theme.civic)
                    StatusPill(
                        title: "\(overrideCount) forced seat\(overrideCount == 1 ? "" : "s")",
                        symbol: overrideCount == 0 ? "function" : "pin.fill",
                        tint: overrideCount == 0 ? Theme.civic : Theme.ind
                    )
                    Spacer()
                }

                Card(
                    title: "National environment",
                    subtitle: "A uniform cycle-level shift. Positive values favor Democrats; negative values favor Republicans.",
                    symbol: "wind",
                    tint: Theme.ind
                ) {
                    SliderRow(
                        label: "Environment vs baseline",
                        value: model.senateEnvBinding(cycle.year),
                        range: -15...15,
                        step: 0.5,
                        format: { plusMinus($0) },
                        accent: Theme.ind,
                        width: 150
                    )
                }

                Card(
                    title: "Seats up this cycle",
                    subtitle: "The model combines state lean, the cycle environment, and incumbency. Each override cycles Model → D → R.",
                    symbol: "list.bullet.rectangle",
                    tint: Theme.civic
                ) {
                    VStack(spacing: 0) {
                        if let result {
                            ForEach(Array(result.outcomes.enumerated()), id: \.element.id) { index, outcome in
                                seatRow(outcome, year: cycle.year)
                                if index < result.outcomes.count - 1 { Divider().opacity(0.55) }
                            }
                        } else {
                            EmptyState(title: "Cycle unavailable", detail: "No modeled outcomes were produced for this cycle.", symbol: "calendar.badge.exclamationmark")
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func seatRow(_ outcome: SeatOutcome, year: Int) -> some View {
        let forced = model.senateOverride(year: year, seatID: outcome.seat.id)
        let stateTitle = Static.name(outcome.seat.state)
        let stateColor = forced.map { Theme.color($0) } ?? Theme.civic
        let stateText = forced == nil ? "Model" : "Forced \(forced!.short)"

        return HStack(spacing: 10) {
            outcome.winner.swatch
            VStack(alignment: .leading, spacing: 2) {
                Text(stateTitle).font(.system(size: 11, weight: .semibold))
                Text("\(outcome.seat.holder) (\(outcome.seat.party.short))")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            StatusPill(title: outcome.rating.rawValue, symbol: "gauge.with.dots.needle.50percent", tint: Theme.color(outcome.rating))
            Text(plusMinus(outcome.margin))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 54, alignment: .trailing)
            Button {
                model.cycleSenateOverride(year: year, seatID: outcome.seat.id)
            } label: {
                Label(stateText, systemImage: forced == nil ? "function" : "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 78)
                    .frame(minHeight: 26)
            }
            .buttonStyle(.bordered)
            .tint(stateColor)
            .accessibilityLabel("\(stateTitle) outcome: \(stateText)")
            .accessibilityHint("Cycles model, forced Democratic, and forced Republican")
        }
        .padding(.vertical, 7)
    }

    private func roman(_ number: Int) -> String {
        ["", "I", "II", "III"][min(number, 3)]
    }
}
