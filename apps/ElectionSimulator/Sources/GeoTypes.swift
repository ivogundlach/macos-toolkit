import Foundation

// Pilot-state redistricting data (decoded from GeneratedData.pilotJSON).

struct PCounty: Codable, Identifiable, Hashable {
    let fips: String
    let name: String
    let pop: Int
    let dem: Int
    let rep: Int
    let rings: [[[Double]]]      // [ring][point][lon, lat]
    var id: String { fips }
    var lean: Double {           // points, + = Dem, two-party
        let t = Double(dem + rep)
        return t > 0 ? (Double(dem) / t - 0.5) * 100 : 0
    }
}

struct PEnsemble: Codable, Hashable {
    let numMaps: Int
    let demSeatHist: [Int]
    let demSeatMean: Double
    let medianMaxDev: Double
    let method: String
}

struct PilotState: Codable {
    let code: String
    let name: String
    let numDistricts: Int
    let statePop: Int
    let counties: [PCounty]
    let adjacency: [String: [String]]
    let ensemble: PEnsemble?
    let seedAssignment: [String: Int]?
    let unit: String?              // "county" (default) or "precinct"

    var idealPop: Int { statePop / numDistricts }
    var unitNoun: String { unit ?? "county" }
    var unitPlural: String { unitNoun == "precinct" ? "precincts" : "counties" }
}

struct PilotsFile: Codable {
    let pilots: [PilotState]
    let infeasible: [String: String]
}

extension Static {
    static let pilotsFile: PilotsFile? = {
        guard let js = GeneratedData.pilotsJSON else { return nil }
        return try? JSONDecoder().decode(PilotsFile.self, from: Data(js.utf8))
    }()
    static var pilots: [PilotState] { (pilotsFile?.pilots ?? []).sorted { $0.name < $1.name } }
    static var infeasiblePilots: [String: String] { pilotsFile?.infeasible ?? [:] }
    static func pilot(_ code: String) -> PilotState? { pilots.first { $0.code == code } }
    /// Convenience default for the redistricting tab / tests.
    static var pilot: PilotState? { pilot("IA") ?? pilots.first }
}
