import SwiftUI

struct PresidentialView: View {
    private var model: AppModel { AppModel.shared }

    private let columns = 12
    private let rows = 8
    private let tile: CGFloat = 60

    var body: some View {
        let result = model.president
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(
                    eyebrow: "Electoral College",
                    title: "Presidential map",
                    detail: "Apply a national swing, choose the electoral-vote basis, split eligible states by congressional district, or directly override any statewide winner.",
                    symbol: "flag"
                )

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    resultCard(result)
                    controlsCard
                }

                cartogramCard(result)
            }
            .padding(16)
        }
    }

    private func resultCard(_ result: ScenarioEngine.PresResult) -> some View {
        let winner = result.winner
        return Card(
            title: "Electoral-vote result",
            subtitle: model.scenario.evBasis2030 ? "Projected 2030 apportionment" : "Current 2020 Census apportionment",
            symbol: "checkmark.seal",
            tint: winner.map { Theme.color($0) } ?? Theme.toss
        ) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .firstTextBaseline) {
                    Text("D \(result.demEV)")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.dem)
                    Spacer()
                    StatusPill(
                        title: winner.map { "\($0.name) wins" } ?? "269–269 tie",
                        symbol: winner == nil ? "equal.circle.fill" : "checkmark.seal.fill",
                        tint: winner.map { Theme.color($0) } ?? Theme.toss
                    )
                    Spacer()
                    Text("R \(result.repEV)")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.rep)
                }
                CompositionBar(dem: result.demEV, rep: result.repEV, total: 538, majorityAt: 270, height: 25)
                HStack {
                    Text("270 to win")
                    Spacer()
                    Text("\(model.scenario.presOverride.count) direct override\(model.scenario.presOverride.count == 1 ? "" : "s")")
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var controlsCard: some View {
        Card(
            title: "National swing and allocation rules",
            subtitle: "Positive swing favors Democrats; negative swing favors Republicans.",
            symbol: "slider.horizontal.3",
            tint: Theme.ind
        ) {
            VStack(alignment: .leading, spacing: 10) {
                SliderRow(
                    label: "Swing vs 2024",
                    value: model.presSwingBinding,
                    range: -15...15,
                    step: 0.5,
                    format: { plusMinus($0) },
                    accent: Theme.ind,
                    width: 105
                )
                Divider()
                Toggle(
                    "Use projected 2030 electoral-vote apportionment",
                    isOn: Binding(
                        get: { model.scenario.evBasis2030 },
                        set: { model.scenario.evBasis2030 = $0 }
                    )
                )
                .font(.system(size: 11, weight: .medium))
                .toggleStyle(.switch)
                .accessibilityHint("Changes each state's electoral-vote count and counts as a scenario edit")
                splitControl
            }
        }
    }

    private var splitControl: some View {
        let splits = Static.votingStates.filter { model.isSplit($0.code) }.sorted { $0.name < $1.name }
        return VStack(alignment: .leading, spacing: 7) {
            Menu {
                ForEach(Static.votingStates.filter { $0.canSplit }.sorted { $0.name < $1.name }) { state in
                    Button {
                        model.toggleSplit(state.code)
                    } label: {
                        Label(
                            "\(state.name) · \(state.seats2020) districts",
                            systemImage: model.isSplit(state.code) ? "checkmark.square.fill" : "square"
                        )
                    }
                }
            } label: {
                Label("Manage split states", systemImage: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(splits) { state in
                        Button {
                            model.toggleSplit(state.code)
                        } label: {
                            Label(state.code, systemImage: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Theme.ind.opacity(0.12)))
                                .overlay(Capsule().stroke(Theme.ind.opacity(0.22), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.ind)
                        .help("Stop splitting \(state.name)")
                    }
                    Text("2 statewide EV + one per 2024 congressional district")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func cartogramCard(_ result: ScenarioEngine.PresResult) -> some View {
        Card(
            title: "State outcome cartogram",
            subtitle: "Each tile names the modeled winner and electoral votes. Activate a tile to cycle Model → D → R.",
            symbol: "map.fill",
            tint: Theme.civic
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    StatusPill(title: "D winner", symbol: "d.circle.fill", tint: Theme.dem)
                    StatusPill(title: "R winner", symbol: "r.circle.fill", tint: Theme.rep)
                    StatusPill(title: "Split EV", symbol: "arrow.triangle.branch", tint: Theme.ind)
                    StatusPill(title: "Forced", symbol: "pin.fill", tint: Theme.civic)
                    Spacer()
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    cartogram(result)
                        .padding(8)
                }
                .refractiveInset(cornerRadius: 11)
                Text("Maine and Nebraska begin in split mode. Any state with congressional-district data can be added through Manage split states.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    private func cartogram(_ result: ScenarioEngine.PresResult) -> some View {
        let byCode = Dictionary(uniqueKeysWithValues: result.states.map { ($0.state.code, $0) })
        return ZStack(alignment: .topLeading) {
            ForEach(Static.states) { state in
                if let row = byCode[state.code] {
                    tileView(row)
                        .offset(
                            x: CGFloat(state.tileCol) * (tile + 4),
                            y: CGFloat(state.tileRow) * (tile + 4)
                        )
                }
            }
        }
        .frame(
            width: CGFloat(columns) * (tile + 4),
            height: CGFloat(rows) * (tile + 4),
            alignment: .topLeading
        )
    }

    private func tileView(_ row: ScenarioEngine.PresState) -> some View {
        Button {
            model.cyclePresOverride(row.state.code)
        } label: {
            VStack(spacing: 1) {
                HStack(spacing: 3) {
                    Text(row.state.code).font(.system(size: 12, weight: .bold))
                    if row.forced {
                        Image(systemName: "pin.fill").font(.system(size: 7, weight: .bold))
                    }
                }
                if row.split {
                    Text("\(row.demEV)D · \(row.repEV)R")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .monospacedDigit()
                } else {
                    Text("\(row.winner.short) · \(row.ev) EV")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
            .frame(width: tile, height: tile)
            .background(RoundedRectangle(cornerRadius: 8).fill(splitFill(row)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(row.forced ? 0.95 : row.split ? 0.62 : 0.28), lineWidth: row.forced ? 2 : 1))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help("\(row.state.name): \(String(format: "%.1f", row.demShare))% two-party Democratic · \(row.split ? "split \(row.demEV)D–\(row.repEV)R" : "\(row.winner.name), \(row.ev) EV")\(row.forced ? " · forced" : " · model")")
        .accessibilityLabel("\(row.state.name), \(row.split ? "split \(row.demEV) Democratic and \(row.repEV) Republican electoral votes" : "\(row.winner.name) wins \(row.ev) electoral votes"), \(row.forced ? "forced outcome" : "model outcome")")
        .accessibilityHint("Cycles model, forced Democratic, and forced Republican")
    }

    private func splitFill(_ row: ScenarioEngine.PresState) -> some ShapeStyle {
        if row.split && row.demEV > 0 && row.repEV > 0 {
            let fraction = Double(row.demEV) / Double(max(1, row.ev))
            return AnyShapeStyle(
                LinearGradient(
                    stops: [
                        .init(color: Theme.dem, location: 0),
                        .init(color: Theme.dem, location: fraction),
                        .init(color: Theme.rep, location: fraction),
                        .init(color: Theme.rep, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        return AnyShapeStyle(Theme.color(row.winner))
    }
}
