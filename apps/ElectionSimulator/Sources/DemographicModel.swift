import Foundation

/// The House generic-ballot model driven by racial-group composition, turnout, and support.
/// Every input is user-adjustable; defaults come from the embedded 2024 real-data table.
struct DemoInputs {
    var support: [String: Double]   // group key -> two-party Dem support (0…1)
    var turnout: [String: Double]   // group key -> turnout rate (0…1)
    var projYear: Int               // electorate composition projected to this year (2024 = baseline)

    static func defaults() -> DemoInputs {
        var s: [String: Double] = [:], t: [String: Double] = [:]
        for g in Static.groups { s[g.key] = g.dem2p; t[g.key] = g.turnout }
        return DemoInputs(support: s, turnout: t, projYear: 2024)
    }
}

/// Annual composition trend of the eligible electorate (points/yr), reflecting real diversification.
/// White declines, Hispanic/Asian/Other rise; renormalized to 1. Source: ACS trend, approx.
private let COMP_TREND: [String: Double] = [
    "white": -0.0035, "black": 0.0000, "hispanic": 0.0022,
    "asian": 0.0007, "native": 0.0000, "other": 0.0006,
]

struct GroupContribution: Identifiable {
    let key: String
    let label: String
    let compShare: Double      // projected composition share of the electorate (voters)
    let support: Double
    var id: String { key }
}

struct DemoResult {
    var nationalDem2p: Double          // national two-party Dem share of the House popular vote (0…1)
    var demSeats: Int
    var repSeats: Int
    var contributions: [GroupContribution]
}

enum DemographicModel {

    /// Composition (CVAP share) projected from 2024 to `year` using COMP_TREND, renormalized.
    static func projectedComposition(to year: Int) -> [String: Double] {
        let dy = Double(year - 2024)
        var comp: [String: Double] = [:]
        for g in Static.groups {
            comp[g.key] = max(0.0001, g.cvapShare + (COMP_TREND[g.key] ?? 0) * dy)
        }
        let sum = comp.values.reduce(0, +)
        for k in comp.keys { comp[k]! /= sum }
        return comp
    }

    static func evaluate(_ inp: DemoInputs) -> DemoResult {
        let comp = projectedComposition(to: inp.projYear)
        var num = 0.0, den = 0.0
        var voterWeight: [String: Double] = [:]
        for g in Static.groups {
            let w = (comp[g.key] ?? 0) * (inp.turnout[g.key] ?? g.turnout)   // share of the electorate
            voterWeight[g.key] = w
            num += w * (inp.support[g.key] ?? g.dem2p)
            den += w
        }
        let dem2p = den > 0 ? num / den : 0.5
        let totalVoter = voterWeight.values.reduce(0, +)

        let sv = Static.seatsVotes
        var seatShare = 0.5 + sv.swingRatio * (dem2p - 0.5) - sv.seatBias
        seatShare = min(0.999, max(0.001, seatShare))
        let demSeats = Int((Double(sv.houseSize) * seatShare).rounded())

        let contribs = Static.groups.map { g in
            GroupContribution(key: g.key, label: g.label,
                              compShare: totalVoter > 0 ? (voterWeight[g.key] ?? 0) / totalVoter : 0,
                              support: inp.support[g.key] ?? g.dem2p)
        }
        return DemoResult(nationalDem2p: dem2p, demSeats: demSeats,
                          repSeats: sv.houseSize - demSeats, contributions: contribs)
    }
}
