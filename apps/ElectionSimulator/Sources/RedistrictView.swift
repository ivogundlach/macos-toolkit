import SwiftUI

private struct MapProjection {
    let minLon: Double
    let maxLon: Double
    let minLat: Double
    let maxLat: Double
    let longitudeScale: Double
    let scale: Double
    let size: CGSize

    init(_ counties: [PCounty], width: Double) {
        var minLongitude = 999.0
        var maxLongitude = -999.0
        var minLatitude = 999.0
        var maxLatitude = -999.0
        for county in counties {
            for ring in county.rings {
                for point in ring {
                    minLongitude = min(minLongitude, point[0])
                    maxLongitude = max(maxLongitude, point[0])
                    minLatitude = min(minLatitude, point[1])
                    maxLatitude = max(maxLatitude, point[1])
                }
            }
        }
        minLon = minLongitude
        maxLon = maxLongitude
        minLat = minLatitude
        maxLat = maxLatitude
        longitudeScale = cos((minLatitude + maxLatitude) / 2 * .pi / 180)
        let longitudeWidth = (maxLongitude - minLongitude) * longitudeScale
        let latitudeHeight = maxLatitude - minLatitude
        scale = width / longitudeWidth
        size = CGSize(width: width, height: latitudeHeight * scale)
    }

    func point(_ longitude: Double, _ latitude: Double) -> CGPoint {
        CGPoint(
            x: (longitude - minLon) * longitudeScale * scale,
            y: (maxLat - latitude) * scale
        )
    }

    func ringPath(_ ring: [[Double]]) -> Path {
        var path = Path()
        for (index, pointValue) in ring.enumerated() {
            let mapped = point(pointValue[0], pointValue[1])
            if index == 0 { path.move(to: mapped) } else { path.addLine(to: mapped) }
        }
        path.closeSubpath()
        return path
    }

    func hit(_ location: CGPoint, _ counties: [PCounty]) -> String? {
        for county in counties {
            for ring in county.rings where pointInRing(location, ring) {
                return county.fips
            }
        }
        return nil
    }

    private func pointInRing(_ location: CGPoint, _ ring: [[Double]]) -> Bool {
        var inside = false
        var previous = ring.count - 1
        for index in 0..<ring.count {
            let currentPoint = point(ring[index][0], ring[index][1])
            let previousPoint = point(ring[previous][0], ring[previous][1])
            if (currentPoint.y > location.y) != (previousPoint.y > location.y) {
                let crossing = (previousPoint.x - currentPoint.x)
                    * (location.y - currentPoint.y)
                    / (previousPoint.y - currentPoint.y)
                    + currentPoint.x
                if location.x < crossing { inside.toggle() }
            }
            previous = index
        }
        return inside
    }
}

struct RedistrictView: View {
    private var model: AppModel { AppModel.shared }

    private static let palette: [Color] = [
        Color(red: 0.14, green: 0.55, blue: 0.58),
        Color(red: 0.82, green: 0.47, blue: 0.16),
        Color(red: 0.45, green: 0.34, blue: 0.68),
        Color(red: 0.48, green: 0.55, blue: 0.18),
        Color(red: 0.75, green: 0.31, blue: 0.50),
        Color(red: 0.27, green: 0.49, blue: 0.75)
    ]

    private func districtColor(_ index: Int) -> Color {
        Self.palette[index % Self.palette.count]
    }

    var body: some View {
        if let pilot = model.pilot {
            HSplitView {
                ScrollView { mapPane(pilot).padding(16) }
                    .frame(minWidth: 620)
                ScrollView { sidePane(pilot).padding(16) }
                    .frame(minWidth: 360, idealWidth: 405)
                    .background(Theme.grouped)
            }
        } else {
            EmptyState(
                title: "Redistricting data unavailable",
                detail: "No embedded pilot map can be selected in this build.",
                symbol: "map"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func mapPane(_ pilot: PilotState) -> some View {
        let projection = MapProjection(pilot.counties, width: 560)
        return VStack(alignment: .leading, spacing: 14) {
            PageHeader(
                eyebrow: "Interactive district map",
                title: "Redraw \(pilot.name)",
                detail: "Assign each \(pilot.unitNoun) to one of \(pilot.numDistricts) districts and inspect population balance, contiguity, partisan lean, and ensemble plausibility in real time.",
                symbol: "rectangle.split.3x3"
            )

            HStack(spacing: 8) {
                statePicker
                StatusPill(title: "\(pilot.numDistricts) districts", symbol: "square.grid.3x3", tint: Theme.civic)
                StatusPill(
                    title: "\(model.mapEdits) map edit\(model.mapEdits == 1 ? "" : "s")",
                    symbol: model.mapEdits == 0 ? "checkmark.circle.fill" : "paintbrush.fill",
                    tint: model.mapEdits == 0 ? Theme.gain : Theme.ind
                )
                Spacer()
            }

            paletteCard(pilot)
            mapCard(pilot, projection)
        }
    }

    private var statePicker: some View {
        Menu {
            ForEach(Static.pilots, id: \.code) { pilot in
                Button {
                    model.selectPilot(pilot.code)
                } label: {
                    Label(
                        "\(pilot.name) · \(pilot.numDistricts) districts",
                        systemImage: pilot.code == model.selectedPilot ? "checkmark" : "map"
                    )
                }
            }
        } label: {
            Label(model.pilot?.name ?? "Choose state", systemImage: "map")
                .font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose among \(Static.pilots.count) embedded redistricting pilots")
        .accessibilityLabel("Redistricting state: \(model.pilot?.name ?? "none")")
    }

    private func paletteCard(_ pilot: PilotState) -> some View {
        let result = model.redistrict
        return Card(
            title: "Paint district",
            subtitle: "Select a district, then click or drag across the map. Winner labels update with every assignment.",
            symbol: "paintpalette.fill",
            tint: Theme.ind
        ) {
            HStack(alignment: .center, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(0..<pilot.numDistricts, id: \.self) { index in
                            let statistic = result?.stats.first { $0.index == index }
                            districtButton(index, statistic: statistic)
                        }
                    }
                }
                Divider().frame(height: 30)
                Button {
                    model.resetMap()
                } label: {
                    Label("Reset map", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .disabled(model.mapEdits == 0)
                .help("Restore this state's embedded seed assignment")
            }
        }
    }

    private func districtButton(_ index: Int, statistic: DistrictStat?) -> some View {
        let selected = model.selectedDistrict == index
        let color = districtColor(index)
        return Button {
            model.selectedDistrict = index
        } label: {
            HStack(spacing: 5) {
                if selected { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)) }
                Text("D\(index + 1)")
                if let statistic { Text(statistic.winner.short) }
            }
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 8)
            .frame(minHeight: 27)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? color.opacity(0.20) : Theme.panelStrong))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? color : Theme.border, lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("District \(index + 1)\(statistic.map { ", \($0.winner.name) leaning" } ?? "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func mapCard(_ pilot: PilotState, _ projection: MapProjection) -> some View {
        Card(
            title: "\(pilot.name) assignment",
            subtitle: pilot.unitNoun == "precinct"
                ? "Real voting precincts; larger counties cannot serve as valid district building blocks here."
                : "Whole-county assignment for states where county-based redistricting is geographically feasible.",
            symbol: "map.fill",
            tint: Theme.civic
        ) {
            Canvas { context, _ in
                for county in pilot.counties {
                    let district = model.assignment[county.fips]
                    let fill = district.map { districtColor($0) } ?? Color.gray.opacity(0.42)
                    let selected = district == model.selectedDistrict
                    for ring in county.rings {
                        let path = projection.ringPath(ring)
                        context.fill(path, with: .color(fill.opacity(selected ? 0.96 : 0.74)))
                        context.stroke(
                            path,
                            with: .color(selected ? Color.white : Color.black.opacity(0.24)),
                            lineWidth: selected ? 1.2 : 0.4
                        )
                    }
                }
            }
            .frame(width: projection.size.width, height: projection.size.height)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panelStrong))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if let fips = projection.hit(gesture.location, pilot.counties) {
                            model.paint(fips)
                        }
                    }
            )
            .overlay(alignment: .bottomTrailing) {
                Text("Base unit · \(pilot.unitNoun) · \(pilot.unitNoun == "precinct" ? "2016" : "2020") returns")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Theme.canvas.opacity(0.88)))
                    .padding(7)
            }
            .accessibilityLabel("Interactive \(pilot.name) district assignment map")
            .accessibilityHint("Click or drag to assign map units to selected district \(model.selectedDistrict + 1)")
        }
    }

    private func sidePane(_ pilot: PilotState) -> some View {
        let result = model.redistrict
        return VStack(alignment: .leading, spacing: 14) {
            PageHeader(
                eyebrow: "Live diagnostics",
                title: "Map statistics",
                detail: "Validation and partisan outcomes recompute from the current assignment.",
                symbol: "checklist"
            )

            if let result {
                plausibilityCard(pilot, result.plausibility)
                ensembleCard(pilot, result)
                districtsCard(result)
            } else {
                EmptyState(title: "No result", detail: "The selected pilot did not produce district statistics.", symbol: "chart.bar.xaxis")
            }
        }
    }

    private func levelColor(_ level: PlausibilityLevel) -> Color {
        switch level {
        case .typical: return Theme.gain
        case .rare: return Theme.loss
        case .extreme: return Theme.rep
        case .invalid: return Theme.toss
        }
    }

    private func plausibilityCard(_ pilot: PilotState, _ plausibility: Plausibility) -> some View {
        let tint = levelColor(plausibility.level)
        let symbol = plausibility.level == .typical ? "checkmark.seal.fill"
            : plausibility.level == .rare ? "exclamationmark.triangle.fill"
            : plausibility.level == .extreme ? "flame.fill" : "xmark.octagon.fill"

        return Card(
            title: "Plausibility",
            subtitle: "Current map compared with \(plausibility.numMaps) neutral ReCom-style maps.",
            symbol: symbol,
            tint: tint
        ) {
            VStack(alignment: .leading, spacing: 8) {
                StatusPill(title: plausibility.headline, symbol: symbol, tint: tint)
                Text(plausibility.detail)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !plausibility.allContiguous || !plausibility.allAssigned {
                    Label(
                        plausibility.allAssigned
                            ? "Every district must be one connected piece."
                            : "Assign every \(pilot.unitNoun) to a district.",
                        systemImage: "wrench.and.screwdriver.fill"
                    )
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.rep)
                }
            }
        }
    }

    private func ensembleCard(_ pilot: PilotState, _ result: RedistrictResult) -> some View {
        let histogram = pilot.ensemble?.demSeatHist ?? []
        let maximum = max(histogram.max() ?? 1, 1)
        return Card(
            title: "Neutral outcome distribution",
            subtitle: "Democratic seats across \(pilot.numberOfMaps(histogram)) neutral maps; your current result is labeled.",
            symbol: "chart.bar.fill",
            tint: Theme.dem
        ) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(0..<histogram.count, id: \.self) { seats in
                        let current = seats == result.demSeats
                        VStack(spacing: 4) {
                            Text("\(Int(Double(histogram[seats]) / Double(max(pilot.ensemble?.numMaps ?? 1, 1)) * 100))%")
                                .font(.system(size: 8)).foregroundStyle(.secondary)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(current ? Theme.dem : Theme.dem.opacity(0.28))
                                .frame(width: 27, height: max(3, CGFloat(histogram[seats]) / CGFloat(maximum) * 84))
                            Text("\(seats)D")
                                .font(.system(size: 9, weight: current ? .bold : .medium))
                                .foregroundStyle(current ? Theme.dem : Color.secondary)
                            if current {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.dem)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(seats) Democratic districts, \(histogram[seats]) neutral maps\(current ? ", current result" : "")")
                    }
                }
                .frame(minHeight: 118, alignment: .bottom)
            }
        }
    }

    private func districtsCard(_ result: RedistrictResult) -> some View {
        Card(
            title: "Districts",
            subtitle: "Partisan lean, population deviation, and contiguity from the live map.",
            symbol: "list.number",
            tint: Theme.civic
        ) {
            VStack(spacing: 0) {
                ForEach(result.stats) { statistic in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(districtColor(statistic.index))
                            .frame(width: 12, height: 12)
                        Text("D\(statistic.index + 1)")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 28, alignment: .leading)
                        statistic.winner.swatch
                        Text(plusMinus(statistic.lean))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 52, alignment: .leading)
                        Spacer()
                        Text(String(format: "%+.1f%% pop.", statistic.deviation * 100))
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(abs(statistic.deviation) > 0.05 ? Theme.loss : Color.secondary)
                        Label(
                            statistic.contiguous ? "Connected" : "Broken",
                            systemImage: statistic.contiguous ? "link" : "link.badge.plus"
                        )
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(statistic.contiguous ? Theme.gain : Theme.rep)
                    }
                    .padding(.vertical, 7)
                    .accessibilityElement(children: .combine)
                    if statistic.index < result.stats.count - 1 { Divider().opacity(0.45) }
                }
            }
        }
    }
}

private extension PilotState {
    func numberOfMaps(_ histogram: [Int]) -> Int {
        ensemble?.numMaps ?? histogram.reduce(0, +)
    }
}
