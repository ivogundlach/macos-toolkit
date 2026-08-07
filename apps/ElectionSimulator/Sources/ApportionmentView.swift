import SwiftUI

struct ApportionmentView: View {
    private var model: AppModel { AppModel.shared }

    var body: some View {
        let rows = Self.buildRows(model.projection.seats)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(
                    eyebrow: "House allocation",
                    title: "2030 reapportionment",
                    detail: "Compare official 2020 House seats with a Huntington–Hill projection based on state population trends through the 2024 Census estimates.",
                    symbol: "arrow.left.arrow.right"
                )

                summary(rows)
                stateTable(rows)
            }
            .padding(16)
        }
    }

    private struct Row {
        let state: DState
        let current: Int
        let projected: Int
        let delta: Int
    }

    private static func buildRows(_ projectedSeats: [String: Int]) -> [Row] {
        Static.votingStates.map { state in
            let projected = projectedSeats[state.code] ?? state.seats2020
            return Row(state: state, current: state.seats2020, projected: projected, delta: projected - state.seats2020)
        }
        .sorted {
            if $0.projected != $1.projected { return $0.projected > $1.projected }
            return $0.state.name < $1.state.name
        }
    }

    private func summary(_ rows: [Row]) -> some View {
        let gainers = rows.filter { $0.delta > 0 }.sorted { $0.delta > $1.delta }
        let losers = rows.filter { $0.delta < 0 }.sorted { $0.delta < $1.delta }
        let stable = rows.filter { $0.delta == 0 }.count

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            movementCard(
                title: "Projected gains",
                subtitle: "\(gainers.reduce(0) { $0 + $1.delta }) seats shifting in",
                rows: gainers,
                positive: true
            )
            movementCard(
                title: "Projected losses",
                subtitle: "\(losers.reduce(0) { $0 + abs($1.delta) }) seats shifting out",
                rows: losers,
                positive: false
            )
            Card(
                title: "Stable allocations",
                subtitle: "States retaining their current House delegation",
                symbol: "equal.circle",
                tint: Theme.civic
            ) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("\(stable)")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("of 50 voting states")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    StatusPill(title: "435 seats total", symbol: "building.columns", tint: Theme.civic)
                }
            }
        }
    }

    private func movementCard(title: String, subtitle: String, rows: [Row], positive: Bool) -> some View {
        let tint = positive ? Theme.gain : Theme.loss
        return Card(
            title: title,
            subtitle: subtitle,
            symbol: positive ? "arrow.up.right" : "arrow.down.right",
            tint: tint
        ) {
            VStack(alignment: .leading, spacing: 5) {
                if rows.isEmpty {
                    Text("None projected.").font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    ForEach(rows, id: \.state.code) { row in
                        HStack(spacing: 6) {
                            Image(systemName: positive ? "plus" : "minus")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(tint)
                            Text(row.state.name).font(.system(size: 10, weight: .medium))
                            Spacer()
                            Text(row.delta > 0 ? "+\(row.delta)" : "\(row.delta)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(tint)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private func stateTable(_ rows: [Row]) -> some View {
        Card(
            title: "Seats by state",
            subtitle: "Current 2020 allocation, projected 2030 allocation, net change, and resulting 2030 electoral votes.",
            symbol: "tablecells",
            tint: Theme.civic
        ) {
            VStack(spacing: 0) {
                tableHeader
                Divider()
                ForEach(Array(rows.enumerated()), id: \.element.state.code) { index, row in
                    stateRow(row, shaded: index.isMultiple(of: 2))
                    if index < rows.count - 1 { Divider().opacity(0.45) }
                }
            }
        }
    }

    private var tableHeader: some View {
        HStack {
            Text("State")
            Spacer()
            Text("2020").frame(width: 58, alignment: .trailing)
            Text("2030 proj.").frame(width: 70, alignment: .trailing)
            Text("Change").frame(width: 62, alignment: .trailing)
            Text("2030 EV").frame(width: 62, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    private func stateRow(_ row: Row, shaded: Bool) -> some View {
        let tint = row.delta > 0 ? Theme.gain : row.delta < 0 ? Theme.loss : Color.secondary
        let change = row.delta == 0 ? "No change" : row.delta > 0 ? "+\(row.delta)" : "\(row.delta)"

        return HStack(spacing: 8) {
            Image(systemName: row.delta > 0 ? "arrow.up.right" : row.delta < 0 ? "arrow.down.right" : "equal")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(row.state.name).font(.system(size: 11, weight: .medium))
            Spacer()
            Text("\(row.current)").frame(width: 58, alignment: .trailing)
            Text("\(row.projected)").fontWeight(.semibold).frame(width: 70, alignment: .trailing)
            Text(change).fontWeight(.semibold).foregroundStyle(tint).frame(width: 62, alignment: .trailing)
            Text("\(row.projected + 2)").foregroundStyle(.secondary).frame(width: 62, alignment: .trailing)
        }
        .font(.system(size: 11, design: .rounded))
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(shaded ? Theme.grouped : Color.clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.state.name), \(row.current) seats in 2020, \(row.projected) projected in 2030, \(change), \(row.projected + 2) electoral votes")
    }
}
