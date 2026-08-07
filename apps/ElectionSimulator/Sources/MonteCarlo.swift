import Foundation

// Deterministic seeded PRNG so the forecast is stable across re-renders (no flicker).
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

struct MCInputs {
    var sims = 5000
    var senateEnvSd = 3.0      // national-environment uncertainty per cycle (pts)
    var senateRaceSd = 3.0     // idiosyncratic per-race noise (pts)
    var presSwingSd = 2.5      // national presidential-swing uncertainty (pts)
    var presStateSd = 2.0      // per-state noise (pts)
    var houseSd = 1.5          // national House two-party uncertainty (pts)
}

struct Outcome2: Identifiable {            // a (value, count) bar
    let value: Int
    let count: Int
    var id: Int { value }
}

struct MCResult {
    // Senate (chamber at the target cycle)
    let targetYear: Int
    let senatePDem: Double          // P(Democratic caucus ≥ 51)
    let senatePRep: Double
    let senateP5050: Double
    let senateMeanDem: Double
    let senateHist: [Outcome2]      // demCaucus -> count
    // President (next presidential election around the current swing)
    let presPDem: Double
    let presMeanDemEV: Double
    let presHist: [Outcome2]        // demEV bucket -> count
    // House (generic ballot)
    let housePDem: Double
    let houseMeanDemSeats: Double
    let houseHist: [Outcome2]       // demSeats bucket -> count
    let sims: Int
}

enum MonteCarlo {

    private static func gauss(_ mean: Double, _ sd: Double, _ g: inout SplitMix64) -> Double {
        if sd <= 0 { return mean }
        let u1 = max(1e-12, Double.random(in: 0..<1, using: &g))
        let u2 = Double.random(in: 0..<1, using: &g)
        return mean + sd * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    static func run(scenario: ScenarioInputs, demo: DemoInputs, target: Int, mc: MCInputs) -> MCResult {
        var g = SplitMix64(seed: 0xC0FFEE &+ (UInt64(target) &* 2654435761) &+ UInt64(mc.sims))
        let N = max(100, mc.sims)

        // ---- Senate: stochastic chain to the target cycle ----
        let baseParty = Dictionary(uniqueKeysWithValues: Static.senateSeats.map { ($0.id, $0.party) })
        var senateCounts: [Int: Int] = [:]
        var senateDemSum = 0, senateDemWins = 0, senateRepWins = 0, senate50 = 0
        for _ in 0..<N {
            var parties = baseParty
            for cycle in SIM_CYCLES {
                if cycle.year > target { break }
                let env = (scenario.senateEnv[cycle.year] ?? 0) + gauss(0, mc.senateEnvSd, &g)
                let ov = scenario.senateOverride[cycle.year] ?? [:]
                for seat in Static.seats(inClass: cycle.senateClass) {
                    if let f = ov[seat.id] { parties[seat.id] = f; continue }
                    let holder = parties[seat.id] ?? seat.party
                    let inc = holder == .dem ? scenario.incumbency
                            : holder == .rep ? -scenario.incumbency : 0
                    let lean = Static.state(seat.state)?.lean ?? 0
                    let m = lean + env + inc + gauss(0, mc.senateRaceSd, &g)
                    parties[seat.id] = m > 0 ? .dem : .rep
                }
            }
            var demC = 0
            for (_, p) in parties where p.caucus == .dem { demC += 1 }
            senateCounts[demC, default: 0] += 1
            senateDemSum += demC
            if demC >= 51 { senateDemWins += 1 } else if demC == 50 { senate50 += 1 } else { senateRepWins += 1 }
        }

        // ---- President: next presidential election around the current swing ----
        let seats = scenario.evBasis2030 ? Apportionment.projected2030().seats : Apportionment.seats2020()
        let evMap = Apportionment.electoralVotes(seats: seats)
        var presBuckets: [Int: Int] = [:]
        var presDemSum = 0, presDemWins = 0
        for _ in 0..<N {
            let swing = scenario.presSwing + gauss(0, mc.presSwingSd, &g)
            var demEV = 0
            for s in Static.states {
                let forced = scenario.presOverride[s.code]
                let statewide = forced ?? ((s.pres2024Dem2p + swing + gauss(0, mc.presStateSd, &g)) > 50 ? .dem : .rep)
                let totalEV = evMap[s.code] ?? s.ev2020
                if scenario.splitStates.contains(s.code) && s.canSplit {
                    if statewide == .dem { demEV += 2 }
                    for cd in s.cdDem2p where cd + swing + gauss(0, mc.presStateSd, &g) > 50 { demEV += 1 }
                } else if statewide == .dem { demEV += totalEV }
            }
            presDemSum += demEV
            if demEV >= 270 { presDemWins += 1 }
            presBuckets[(demEV / 20) * 20, default: 0] += 1
        }

        // ---- House: generic-ballot uncertainty ----
        let base = DemographicModel.evaluate(demo)
        let sv = Static.seatsVotes
        var houseBuckets: [Int: Int] = [:]
        var houseDemSum = 0, houseDemWins = 0
        if let forced = scenario.houseOverrideDemSeats {
            let demSeats = min(max(forced, 0), sv.houseSize)
            houseDemSum = demSeats * N
            houseDemWins = demSeats >= 218 ? N : 0
            houseBuckets[demSeats, default: 0] = N
        } else {
            for _ in 0..<N {
                let share = base.nationalDem2p + gauss(0, mc.houseSd / 100, &g)
                var ss = 0.5 + sv.swingRatio * (share - 0.5) - sv.seatBias
                ss = min(0.999, max(0.001, ss))
                let demSeats = Int((Double(sv.houseSize) * ss).rounded())
                houseDemSum += demSeats
                if demSeats >= 218 { houseDemWins += 1 }
                houseBuckets[(demSeats / 5) * 5, default: 0] += 1
            }
        }

        func bars(_ d: [Int: Int]) -> [Outcome2] {
            d.keys.sorted().map { Outcome2(value: $0, count: d[$0]!) }
        }
        let n = Double(N)
        return MCResult(
            targetYear: target,
            senatePDem: Double(senateDemWins)/n, senatePRep: Double(senateRepWins)/n,
            senateP5050: Double(senate50)/n, senateMeanDem: Double(senateDemSum)/n,
            senateHist: bars(senateCounts),
            presPDem: Double(presDemWins)/n, presMeanDemEV: Double(presDemSum)/n,
            presHist: bars(presBuckets),
            housePDem: Double(houseDemWins)/n, houseMeanDemSeats: Double(houseDemSum)/n,
            houseHist: bars(houseBuckets), sims: N)
    }
}
