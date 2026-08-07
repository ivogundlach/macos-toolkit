import SwiftUI
import Observation

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // Navigation
    var appMode = 0                   // 0 Simulation · 1 Scenario Builder
    var tab = 0                      // 0 Overview · 1 Senate · 2 House · 3 President · 4 Apportionment
    var selectedSenateCycle = 2032   // which cycle the Senate tab is editing (the headline question)

    // Scenario + demographic inputs (the knobs the user turns)
    var scenario = ScenarioInputs()
    var demo = DemoInputs.defaults()

    // Redistricting (Phase 2) — per-state county→district assignment for every feasible state.
    var selectedPilot = "IA"
    var selectedDistrict = 0
    var assignments: [String: [String: Int]] = [:]

    private init() {
        for p in Static.pilots { assignments[p.code] = p.seedAssignment ?? [:] }
        if Static.pilot(selectedPilot) == nil { selectedPilot = Static.pilots.first?.code ?? "IA" }
    }

    var pilot: PilotState? { Static.pilot(selectedPilot) }
    var assignment: [String: Int] { assignments[selectedPilot] ?? [:] }
    var redistrict: RedistrictResult? {
        guard let p = pilot else { return nil }
        return Redistricting.evaluate(p, assignment)
    }
    func selectPilot(_ code: String) { selectedPilot = code; selectedDistrict = 0 }
    func paint(_ fips: String) {
        var m = assignments[selectedPilot] ?? [:]
        m[fips] = selectedDistrict
        assignments[selectedPilot] = m
    }
    func resetMap() {
        if let seed = Static.pilot(selectedPilot)?.seedAssignment { assignments[selectedPilot] = seed }
    }
    var mapEdits: Int {
        guard let seed = Static.pilot(selectedPilot)?.seedAssignment else { return 0 }
        return assignment.reduce(0) { $0 + (seed[$1.key] == $1.value ? 0 : 1) }
    }

    // MARK: Derived results (recomputed on read; Observation re-renders on input change)

    var senate: (baseline: Composition, results: [CycleResult]) { ScenarioEngine.runSenate(scenario) }
    var president: ScenarioEngine.PresResult { ScenarioEngine.runPresidential(scenario) }
    var houseModel: DemoResult { DemographicModel.evaluate(demo) }
    var house: DemoResult {
        var r = houseModel
        if let forced = scenario.houseOverrideDemSeats {
            let d = min(max(forced, 0), Static.seatsVotes.houseSize)
            r.demSeats = d
            r.repSeats = Static.seatsVotes.houseSize - d
        }
        return r
    }
    var projection: (pops: [String: Double], seats: [String: Int]) { Apportionment.projected2030() }

    // Phase 3 — Monte Carlo forecast around the current scenario.
    var mc = MCInputs()
    var forecast: MCResult { MonteCarlo.run(scenario: scenario, demo: demo, target: selectedSenateCycle, mc: mc) }
    var uncertaintyBinding: Binding<Double> {
        Binding(get: { self.mc.senateEnvSd },
                set: { v in
                    let baseline = MCInputs()
                    let scale = v / baseline.senateEnvSd
                    self.mc.senateEnvSd = baseline.senateEnvSd * scale
                    self.mc.senateRaceSd = baseline.senateRaceSd * scale
                    self.mc.presSwingSd = baseline.presSwingSd * scale
                    self.mc.presStateSd = baseline.presStateSd * scale
                    self.mc.houseSd = baseline.houseSd * scale
                })
    }

    /// Composition after a specific cycle year (e.g. 2032).
    func senateAfter(_ year: Int) -> Composition? {
        senate.results.first { $0.cycle.year == year }?.composition
    }

    // MARK: Edit accounting / reset

    var editCount: Int {
        scenario.senateEnv.values.filter { $0 != 0 }.count
        + scenario.senateOverride.values.reduce(0) { $0 + $1.count }
        + scenario.presOverride.count
        + (scenario.houseOverrideDemSeats == nil ? 0 : 1)
        + (scenario.presSwing != 0 ? 1 : 0)
        + (scenario.evBasis2030 ? 1 : 0)
        + scenario.splitStates.symmetricDifference(["ME", "NE"]).count
        + demoEdits + mcEdits + mapEdits
    }
    private var demoEdits: Int {
        let d = DemoInputs.defaults()
        var n = 0
        for g in Static.groups {
            if demo.support[g.key] != d.support[g.key] { n += 1 }
            if demo.turnout[g.key] != d.turnout[g.key] { n += 1 }
        }
        if demo.projYear != 2024 { n += 1 }
        return n
    }
    private var mcEdits: Int {
        let baseline = MCInputs()
        let changed = mc.sims != baseline.sims
            || abs(mc.senateEnvSd - baseline.senateEnvSd) > 0.0001
            || abs(mc.senateRaceSd - baseline.senateRaceSd) > 0.0001
            || abs(mc.presSwingSd - baseline.presSwingSd) > 0.0001
            || abs(mc.presStateSd - baseline.presStateSd) > 0.0001
            || abs(mc.houseSd - baseline.houseSd) > 0.0001
        return changed ? 1 : 0
    }

    func reset() {
        scenario = ScenarioInputs()
        demo = DemoInputs.defaults()
        mc = MCInputs()
        for p in Static.pilots { assignments[p.code] = p.seedAssignment ?? [:] }
    }

    // MARK: Binding helpers (manual, since SwiftUI state macros are unavailable here)

    func senateEnvBinding(_ year: Int) -> Binding<Double> {
        Binding(get: { self.scenario.senateEnv[year] ?? 0 },
                set: { self.scenario.senateEnv[year] = $0 })
    }
    func supportBinding(_ key: String) -> Binding<Double> {
        Binding(get: { self.demo.support[key] ?? 0 },
                set: { self.demo.support[key] = $0 })
    }
    func turnoutBinding(_ key: String) -> Binding<Double> {
        Binding(get: { self.demo.turnout[key] ?? 0 },
                set: { self.demo.turnout[key] = $0 })
    }
    var projYearBinding: Binding<Double> {
        Binding(get: { Double(self.demo.projYear) },
                set: { self.demo.projYear = Int($0.rounded()) })
    }
    var presSwingBinding: Binding<Double> {
        Binding(get: { self.scenario.presSwing }, set: { self.scenario.presSwing = $0 })
    }
    var houseDirectSeatsBinding: Binding<Double> {
        Binding(get: { Double(self.scenario.houseOverrideDemSeats ?? self.houseModel.demSeats) },
                set: { self.setHouseOverrideDemSeats(Int($0.rounded())) })
    }

    /// Cycle a Senate seat between model / forced-D / forced-R.
    func cycleSenateOverride(year: Int, seatID: String) {
        var m = scenario.senateOverride[year] ?? [:]
        switch m[seatID] {
        case nil:    m[seatID] = .dem
        case .dem:   m[seatID] = .rep
        default:     m[seatID] = nil
        }
        scenario.senateOverride[year] = m
    }
    func senateOverride(year: Int, seatID: String) -> Party? {
        scenario.senateOverride[year]?[seatID]
    }
    func setSenateOverride(year: Int, seatID: String, party: Party?) {
        var m = scenario.senateOverride[year] ?? [:]
        if let party { m[seatID] = party } else { m.removeValue(forKey: seatID) }
        scenario.senateOverride[year] = m
    }

    /// Toggle whether a state splits its electoral votes by congressional district.
    func toggleSplit(_ code: String) {
        if scenario.splitStates.contains(code) { scenario.splitStates.remove(code) }
        else { scenario.splitStates.insert(code) }
    }
    func isSplit(_ code: String) -> Bool { scenario.splitStates.contains(code) }

    /// Toggle a presidential state between model / forced-D / forced-R.
    func cyclePresOverride(_ code: String) {
        switch scenario.presOverride[code] {
        case nil:  scenario.presOverride[code] = .dem
        case .dem: scenario.presOverride[code] = .rep
        default:   scenario.presOverride[code] = nil
        }
    }
    func setPresOverride(_ code: String, party: Party?) {
        if let party { scenario.presOverride[code] = party }
        else { scenario.presOverride.removeValue(forKey: code) }
    }
    func setHouseOverrideDemSeats(_ seats: Int) {
        scenario.houseOverrideDemSeats = min(max(seats, 0), Static.seatsVotes.houseSize)
    }
    func clearHouseOverride() { scenario.houseOverrideDemSeats = nil }
}
