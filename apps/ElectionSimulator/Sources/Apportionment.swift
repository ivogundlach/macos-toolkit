import Foundation

/// House apportionment by the Huntington–Hill method of equal proportions, plus a
/// census-population projection to 2030 used for future seat counts and electoral votes.
enum Apportionment {

    /// Allocate `seats` House seats among states by Huntington–Hill.
    /// Every state gets 1 seat, then each remaining seat goes to the state with the
    /// highest priority value pop / sqrt(n·(n+1)), where n is its current seat count.
    static func huntingtonHill(pops: [String: Double], seats: Int = 435) -> [String: Int] {
        var alloc = Dictionary(uniqueKeysWithValues: pops.keys.map { ($0, 1) })
        var remaining = seats - pops.count
        precondition(remaining >= 0, "more states than seats")
        while remaining > 0 {
            var bestKey = ""
            var bestPV = -1.0
            for (k, p) in pops {
                let n = Double(alloc[k]!)
                let pv = p / (n * (n + 1)).squareRoot()
                if pv > bestPV { bestPV = pv; bestKey = k }
            }
            alloc[bestKey]! += 1
            remaining -= 1
        }
        return alloc
    }

    /// Current (2020 Census) apportionment, straight from the official seat counts.
    static func seats2020() -> [String: Int] {
        Dictionary(uniqueKeysWithValues: Static.votingStates.map { ($0.code, $0.seats2020) })
    }

    /// Project each state's population to ~2030 using the 2020→2024 compound annual rate,
    /// then re-run Huntington–Hill. Returns projected seat counts (sums to 435).
    static func projected2030() -> (pops: [String: Double], seats: [String: Int]) {
        var pops: [String: Double] = [:]
        for s in Static.votingStates {
            guard let base = s.base2020, let p24 = s.pop2024, base > 0 else {
                pops[s.code] = Double(s.pop2020); continue
            }
            // 2020-04-01 base → 2024-07-01 estimate ≈ 4.25 years.
            let cagr = pow(Double(p24) / Double(base), 1.0 / 4.25)
            // project from 2024.5 to ~2030.25 ≈ 5.75 more years.
            pops[s.code] = Double(p24) * pow(cagr, 5.75)
        }
        return (pops, huntingtonHill(pops: pops, seats: 435))
    }

    /// Electoral votes for a given House apportionment: seats + 2 per state, DC = 3. Sums to 538.
    static func electoralVotes(seats: [String: Int]) -> [String: Int] {
        var ev: [String: Int] = [:]
        for s in Static.states {
            if s.isVotingState { ev[s.code] = (seats[s.code] ?? s.seats2020) + 2 }
            else { ev[s.code] = s.ev2020 }   // DC fixed at 3
        }
        return ev
    }
}
