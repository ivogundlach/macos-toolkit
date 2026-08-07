import Foundation

enum Rating: String {
    case safeD = "Safe D", likelyD = "Likely D", leanD = "Lean D", tossup = "Tossup"
    case leanR = "Lean R", likelyR = "Likely R", safeR = "Safe R"

    static func from(margin m: Double) -> Rating {   // m>0 favors Dem
        let a = abs(m)
        if a < 1.5 { return .tossup }
        if m > 0 { return a < 6 ? .leanD : a < 12 ? .likelyD : .safeD }
        return a < 6 ? .leanR : a < 12 ? .likelyR : .safeR
    }
    var party: Party? { self == .tossup ? nil : (rawValue.hasSuffix("D") ? .dem : .rep) }
}

/// Inputs the user controls for the scenario (held on AppModel, passed in here).
struct ScenarioInputs {
    var senateEnv: [Int: Double] = [:]            // cycle year -> national environment (pts, +D)
    var senateOverride: [Int: [String: Party]] = [:]  // year -> seatID -> forced winner
    var incumbency: Double = 2.5                  // pts toward the seat's current holder party
    var presSwing: Double = 0.0                   // national presidential swing (pts, +D)
    var presOverride: [String: Party] = [:]       // state code -> forced winner (statewide)
    var houseOverrideDemSeats: Int? = nil         // direct House outcome, when scenario builder sets it
    var evBasis2030: Bool = false                 // electoral votes on projected 2030 apportionment
    var splitStates: Set<String> = ["ME", "NE"]   // states that split EVs by congressional district
}

struct SeatOutcome: Identifiable {
    let seat: DSenateSeat
    let winner: Party
    let margin: Double
    let rating: Rating
    let forced: Bool
    var id: String { seat.id }
}

struct CycleResult: Identifiable {
    let cycle: Cycle
    let outcomes: [SeatOutcome]
    let composition: Composition      // full chamber composition after this cycle
    var id: Int { cycle.year }
}

enum ScenarioEngine {

    // MARK: Senate

    private static func baselineParties() -> [String: Party] {
        Dictionary(uniqueKeysWithValues: Static.senateSeats.map { ($0.id, $0.party) })
    }

    private static func compose(_ parties: [String: Party]) -> Composition {
        var c = Composition()
        for (_, p) in parties {
            switch p {
            case .dem: c.dem += 1
            case .rep: c.rep += 1
            case .ind: c.ind += 1
            }
            if p.caucus == .dem { c.demCaucus += 1 } else { c.repCaucus += 1 }
        }
        return c
    }

    private static func predict(seat: DSenateSeat, holderParty: Party,
                                env: Double, incumbency: Double) -> (Party, Double) {
        guard let st = Static.state(seat.state) else { return (holderParty, 0) }
        let inc = holderParty == .dem ? incumbency : (holderParty == .rep ? -incumbency : 0)
        let margin = st.lean + env + inc          // >0 favors Dem
        return (margin > 0 ? .dem : .rep, margin)
    }

    /// Chain all cycles from today's baseline; return the per-cycle results in order,
    /// plus the baseline composition snapshot at index 0.
    static func runSenate(_ inp: ScenarioInputs) -> (baseline: Composition, results: [CycleResult]) {
        var parties = baselineParties()
        let baseline = compose(parties)
        var results: [CycleResult] = []
        for cycle in SIM_CYCLES {
            let env = inp.senateEnv[cycle.year] ?? 0
            let overrides = inp.senateOverride[cycle.year] ?? [:]
            var outcomes: [SeatOutcome] = []
            for seat in Static.seats(inClass: cycle.senateClass) {
                let holder = parties[seat.id] ?? seat.party
                let (pred, margin) = predict(seat: seat, holderParty: holder,
                                             env: env, incumbency: inp.incumbency)
                let forcedParty = overrides[seat.id]
                let winner = forcedParty ?? pred
                parties[seat.id] = winner
                outcomes.append(SeatOutcome(seat: seat, winner: winner, margin: margin,
                                            rating: Rating.from(margin: margin),
                                            forced: forcedParty != nil))
            }
            results.append(CycleResult(cycle: cycle, outcomes: outcomes,
                                       composition: compose(parties)))
        }
        return (baseline, results)
    }

    // MARK: Presidential

    struct PresState: Identifiable {
        let state: DState
        let demShare: Double
        let winner: Party        // statewide winner (drives tile color)
        let demEV: Int           // this state's electoral votes going to Democrats
        let repEV: Int
        let split: Bool
        let forced: Bool
        var ev: Int { demEV + repEV }
        var id: String { state.code }
    }
    struct PresResult {
        let states: [PresState]
        let demEV: Int
        let repEV: Int
        var winner: Party? { demEV >= 270 ? .dem : repEV >= 270 ? .rep : nil }
    }

    static func runPresidential(_ inp: ScenarioInputs) -> PresResult {
        let seats = inp.evBasis2030 ? Apportionment.projected2030().seats : Apportionment.seats2020()
        let evMap = Apportionment.electoralVotes(seats: seats)
        var rows: [PresState] = []
        var demEV = 0, repEV = 0
        for s in Static.states {
            let share = s.pres2024Dem2p + inp.presSwing
            let forced = inp.presOverride[s.code]
            let statewide = forced ?? (share > 50 ? .dem : .rep)
            let totalEV = evMap[s.code] ?? s.ev2020
            var dEV = 0, rEV = 0
            let isSplit = inp.splitStates.contains(s.code) && s.canSplit
            if isSplit {
                // 2 electoral votes to the statewide winner, 1 per congressional district.
                if statewide == .dem { dEV += 2 } else { rEV += 2 }
                for cd in s.cdDem2p {
                    if cd + inp.presSwing > 50 { dEV += 1 } else { rEV += 1 }
                }
            } else if statewide == .dem { dEV = totalEV } else { rEV = totalEV }
            demEV += dEV; repEV += rEV
            rows.append(PresState(state: s, demShare: share, winner: statewide,
                                  demEV: dEV, repEV: rEV, split: isSplit, forced: forced != nil))
        }
        return PresResult(states: rows.sorted { $0.state.code < $1.state.code },
                          demEV: demEV, repEV: repEV)
    }
}
