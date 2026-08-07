// Engine self-test — compiled separately from the GUI (Foundation-only sources).
// Verifies apportionment, demographic, and Senate math against known real results.
import Foundation

func check(_ cond: Bool, _ msg: String) {
    print((cond ? "  ✓ " : "  ✗ FAIL ") + msg)
    if !cond { exit(1) }
}

print("Apportionment (Huntington–Hill on 2020 census population):")
let pops = Dictionary(uniqueKeysWithValues: Static.votingStates.map { ($0.code, Double($0.pop2020)) })
let hh = Apportionment.huntingtonHill(pops: pops, seats: 435)
check(hh.values.reduce(0, +) == 435, "total seats = 435")
check(hh["CA"] == 52, "California = 52 (got \(hh["CA"] ?? -1))")
check(hh["TX"] == 38, "Texas = 38 (got \(hh["TX"] ?? -1))")
check(hh["FL"] == 28, "Florida = 28 (got \(hh["FL"] ?? -1))")
check(hh["NY"] == 26, "New York = 26 (got \(hh["NY"] ?? -1))")
var exact = true
for s in Static.votingStates where hh[s.code] != s.seats2020 { exact = false
    print("    mismatch \(s.code): HH \(hh[s.code] ?? -1) vs official \(s.seats2020)") }
check(exact, "HH reproduces the official allocation for all 50 states")

let ev = Apportionment.electoralVotes(seats: Apportionment.seats2020())
check(ev.values.reduce(0, +) == 538, "electoral votes total = 538")

print("\nDemographic generic-ballot model (2024 defaults):")
let dm = DemographicModel.evaluate(.defaults())
print(String(format: "  national two-party Dem = %.1f%%, seats D %d / R %d",
             dm.nationalDem2p * 100, dm.demSeats, dm.repSeats))
check(abs(dm.nationalDem2p - 0.482) < 0.01, "national two-party Dem ≈ 48.2% (2024)")
check(dm.demSeats >= 210 && dm.demSeats <= 220, "Dem seats in 210–220 band (2024 actual 215)")

print("\nSenate baseline + chained scenario (model defaults, no edits):")
let sen = ScenarioEngine.runSenate(ScenarioInputs())
let b = sen.baseline
print("  baseline: D\(b.dem) I\(b.ind) R\(b.rep)  → caucus D\(b.demCaucus) / R\(b.repCaucus)")
check(b.dem == 45 && b.ind == 2 && b.rep == 53, "baseline 45D / 2I / 53R")
check(b.demCaucus == 47 && b.repCaucus == 53, "caucus split 47–53")
for r in sen.results {
    let c = r.composition
    print("  after \(r.cycle.year): caucus D\(c.demCaucus) / R\(c.repCaucus)"
          + (c.demCaucus >= 51 ? "  (D majority)" : c.repCaucus >= 51 ? "  (R majority)" : "  (50–50)"))
}
check(sen.results.count == 5, "five cycles chained (2026→2034)")

print("\nRedistricting pilot (Iowa) — geometry, recompute, plausibility:")
if let pilot = Static.pilot {
    check(pilot.counties.count == 99, "99 counties loaded")
    check(pilot.code == "IA" && pilot.numDistricts == 4, "Iowa, 4 districts")
    let hist = pilot.ensemble?.demSeatHist ?? []
    check((pilot.ensemble?.numMaps ?? 0) == hist.reduce(0, +), "ensemble histogram sums to numMaps")
    let seed = pilot.seedAssignment ?? [:]
    check(seed.count == 99, "seed assigns all 99 counties")
    let r = Redistricting.evaluate(pilot, seed)
    print(String(format: "  seed map: %d Dem districts, all-contiguous %@, max dev %.1f%%",
                 r.demSeats, r.plausibility.allContiguous ? "yes" : "no", r.plausibility.maxDevPct))
    check(r.plausibility.allAssigned, "seed map fully assigned")
    check(r.plausibility.allContiguous, "seed map all districts contiguous")
    check(r.plausibility.level == .typical, "seed map scores as typical (it came from the ensemble)")
    // A 3-Dem map would be impossible under neutral maps:
    check(hist.count > 3 && hist[3] == 0, "3 Dem districts never occurred in the neutral ensemble (extreme)")
} else {
    print("  ! pilot data not embedded (run ./tools/fetch.sh)")
}

print("\nGeorgia precinct-level redistricting pilot:")
if let ga = Static.pilot("GA") {
    print("  \(ga.counties.count) precincts, \(ga.numDistricts) districts, ensemble hist \(ga.ensemble?.demSeatHist ?? [])")
    check(ga.unit == "precinct", "Georgia uses precinct units")
    check(ga.counties.count > 2000, "Georgia has 2000+ precincts (got \(ga.counties.count))")
    check(ga.numDistricts == 14, "Georgia has 14 districts")
    let gr = Redistricting.evaluate(ga, ga.seedAssignment ?? [:])
    print("  seed map: \(gr.demSeats) Dem districts, contiguous \(gr.plausibility.allContiguous), max dev \(String(format: "%.1f", gr.plausibility.maxDevPct))%")
    check(gr.plausibility.allAssigned && gr.plausibility.allContiguous, "Georgia seed map is valid")
    check((ga.ensemble?.demSeatHist.count ?? 0) == 15, "Georgia ensemble histogram has 15 buckets (0–14)")
} else {
    print("  ! Georgia precinct pilot not embedded")
}
check(Static.pilots.count == 15, "15 redistricting pilots embedded (14 county + GA precinct)")

print("\nPresidential electoral-vote splitting (default: ME, NE split by district):")
let pres = ScenarioEngine.runPresidential(ScenarioInputs())
check(pres.demEV + pres.repEV == 538, "total electoral votes = 538 (got \(pres.demEV + pres.repEV))")
let meRow = pres.states.first { $0.state.code == "ME" }!
let neRow = pres.states.first { $0.state.code == "NE" }!
print("  ME \(meRow.demEV)D–\(meRow.repEV)R · NE \(neRow.demEV)D–\(neRow.repEV)R · national D\(pres.demEV)/R\(pres.repEV)")
check(meRow.split && meRow.demEV == 3 && meRow.repEV == 1, "Maine splits 3D–1R")
check(neRow.split && neRow.demEV == 1 && neRow.repEV == 4, "Nebraska splits 1D–4R")
var spGA = ScenarioInputs(); spGA.splitStates.insert("GA")
let presGA = ScenarioEngine.runPresidential(spGA)
let gaRow = presGA.states.first { $0.state.code == "GA" }!
print("  Georgia split (toggled on): \(gaRow.demEV)D–\(gaRow.repEV)R of 16")
check(presGA.demEV + presGA.repEV == 538, "total EV still 538 with Georgia split")
check(gaRow.split && gaRow.demEV + gaRow.repEV == 16, "Georgia split totals its 16 EV")

print("\nMonte Carlo forecast (default scenario, 2032 Senate target):")
let mc = MonteCarlo.run(scenario: ScenarioInputs(), demo: .defaults(), target: 2032, mc: MCInputs())
print(String(format: "  Senate: P(Dem)=%.0f%% P(Rep)=%.0f%% P(50-50)=%.0f%% mean %.1f Dem",
             mc.senatePDem*100, mc.senatePRep*100, mc.senateP5050*100, mc.senateMeanDem))
print(String(format: "  President: P(Dem)=%.0f%% mean %.0f Dem EV", mc.presPDem*100, mc.presMeanDemEV))
print(String(format: "  House: P(Dem)=%.0f%% mean %.0f Dem seats", mc.housePDem*100, mc.houseMeanDemSeats))
let psum = mc.senatePDem + mc.senatePRep + mc.senateP5050
check(abs(psum - 1.0) < 0.001, "Senate outcome probabilities sum to 1")
check(mc.senateHist.reduce(0){$0+$1.count} == mc.sims, "Senate histogram counts == sims")
check(mc.presPDem >= 0 && mc.presPDem <= 1, "President probability in [0,1]")
check(mc.presMeanDemEV > 150 && mc.presMeanDemEV < 320, "President mean Dem EV in a sane band")

print("\nALL CHECKS PASSED")
