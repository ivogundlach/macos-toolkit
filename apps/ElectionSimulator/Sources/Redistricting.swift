import Foundation

struct DistrictStat: Identifiable {
    let index: Int
    let pop: Int
    let dem: Int
    let rep: Int
    let counties: Int
    let contiguous: Bool
    let idealPop: Int
    var winner: Party { dem >= rep ? .dem : .rep }
    var lean: Double { let t = Double(dem + rep); return t > 0 ? (Double(dem)/t - 0.5)*100 : 0 }
    var deviation: Double { idealPop > 0 ? Double(pop - idealPop) / Double(idealPop) : 0 }
    var id: Int { index }
}

enum PlausibilityLevel: Int { case typical = 0, rare = 1, extreme = 2, invalid = 3 }

struct Plausibility {
    let demSeats: Int
    let frequencyPct: Double          // % of neutral maps with this Dem-seat count
    let ensembleMean: Double
    let numMaps: Int
    let maxDevPct: Double             // worst district population deviation
    let allContiguous: Bool
    let allAssigned: Bool
    let level: PlausibilityLevel
    let headline: String
    let detail: String
}

struct RedistrictResult {
    let stats: [DistrictStat]
    let plausibility: Plausibility
    let idealPop: Int
    let demSeats: Int
}

enum Redistricting {

    private static func contiguous(_ members: [String], adjacency: [String: [String]]) -> Bool {
        guard let start = members.first else { return false }
        let set = Set(members)
        var seen: Set<String> = [start]
        var stack = [start]
        while let u = stack.popLast() {
            for v in adjacency[u] ?? [] where set.contains(v) && !seen.contains(v) {
                seen.insert(v); stack.append(v)
            }
        }
        return seen.count == set.count
    }

    static func evaluate(_ pilot: PilotState, _ assignment: [String: Int]) -> RedistrictResult {
        let K = pilot.numDistricts
        let ideal = pilot.idealPop
        var pop = Array(repeating: 0, count: K)
        var dem = Array(repeating: 0, count: K)
        var rep = Array(repeating: 0, count: K)
        var members = Array(repeating: [String](), count: K)
        var assignedAll = true
        for c in pilot.counties {
            guard let d = assignment[c.fips], d >= 0, d < K else { assignedAll = false; continue }
            pop[d] += c.pop; dem[d] += c.dem; rep[d] += c.rep; members[d].append(c.fips)
        }

        var stats: [DistrictStat] = []
        var demSeats = 0
        var maxDev = 0.0
        var allContig = true
        for d in 0..<K {
            let contig = contiguous(members[d], adjacency: pilot.adjacency)
            if !contig { allContig = false }
            let s = DistrictStat(index: d, pop: pop[d], dem: dem[d], rep: rep[d],
                                 counties: members[d].count, contiguous: contig, idealPop: ideal)
            if s.winner == .dem && (dem[d] + rep[d]) > 0 { demSeats += 1 }
            maxDev = max(maxDev, abs(s.deviation))
            stats.append(s)
        }

        let plaus = score(pilot: pilot, demSeats: demSeats, maxDevPct: maxDev * 100,
                          allContiguous: allContig, allAssigned: assignedAll)
        return RedistrictResult(stats: stats, plausibility: plaus, idealPop: ideal, demSeats: demSeats)
    }

    private static func score(pilot: PilotState, demSeats: Int, maxDevPct: Double,
                              allContiguous: Bool, allAssigned: Bool) -> Plausibility {
        let ens = pilot.ensemble
        let n = ens?.numMaps ?? 0
        let hist = ens?.demSeatHist ?? []
        let freq = (n > 0 && demSeats < hist.count) ? Double(hist[demSeats]) / Double(n) * 100 : 0
        let mean = ens?.demSeatMean ?? 0

        var level: PlausibilityLevel
        var headline: String
        if !allAssigned || !allContiguous {
            level = .invalid
            headline = !allAssigned ? "Incomplete map — some counties unassigned"
                                    : "Invalid map — a district is not contiguous"
        } else if n == 0 {
            level = .typical; headline = "No ensemble available"
        } else if freq == 0 {
            level = .extreme
            headline = "Extreme outlier — \(demSeats) Dem district\(demSeats == 1 ? "" : "s") never occurred in \(n) neutral maps"
        } else if freq < 5 {
            level = .rare
            headline = String(format: "Rare — only %.1f%% of %d neutral maps produced %d Dem district%@",
                              freq, n, demSeats, demSeats == 1 ? "" : "s")
        } else {
            level = .typical
            headline = String(format: "Within the neutral range — %.0f%% of maps give %d Dem district%@",
                              freq, demSeats, demSeats == 1 ? "" : "s")
        }

        let detail = String(format: "Neutral maps average %.2f Democratic seats. Worst district population deviation in your map: %.1f%%%@.",
                            mean, maxDevPct, allContiguous ? "" : " · contiguity broken")
        return Plausibility(demSeats: demSeats, frequencyPct: freq, ensembleMean: mean, numMaps: n,
                            maxDevPct: maxDevPct, allContiguous: allContiguous, allAssigned: allAssigned,
                            level: level, headline: headline, detail: detail)
    }
}
