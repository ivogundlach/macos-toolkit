import Foundation

// MARK: - Party

enum Party: String, Codable, CaseIterable, Hashable {
    case dem = "D", rep = "R", ind = "I"
    var short: String { rawValue }
    var name: String { self == .dem ? "Democratic" : self == .rep ? "Republican" : "Independent" }
    /// Both current independents (Sanders-VT, King-ME) caucus with Democrats.
    var caucus: Party { self == .ind ? .dem : self }
}

// MARK: - Decoded dataset (matches Resources/dataset.json)

struct DState: Codable, Identifiable, Hashable {
    let code: String
    let name: String
    let pop2020: Int
    let seats2020: Int
    let pop2024: Int?
    let base2020: Int?
    let ev2020: Int
    let pres2024Dem2p: Double      // two-party Dem share of 2024 presidential vote (%)
    let cdDem2p: [Double]          // per-congressional-district 2024 two-party Dem % (for EV splits)
    let tile: [Int]                // [col, row] cartogram position
    let nonState: Bool?

    var id: String { code }
    var isVotingState: Bool { (nonState ?? false) == false }   // false only for DC
    /// A state can split its electoral votes by district only if we have a lean for every district.
    var canSplit: Bool { isVotingState && cdDem2p.count == seats2020 && seats2020 >= 1 }
    var tileCol: Int { tile.first ?? 0 }
    var tileRow: Int { tile.count > 1 ? tile[1] : 0 }
    /// Partisan lean in points relative to an even 50/50 (positive = Democratic).
    var lean: Double { pres2024Dem2p - 50.0 }
}

struct DSenateSeat: Codable, Identifiable, Hashable {
    let state: String
    let cls: Int
    let party: Party
    let caucus: Party
    let holder: String
    var id: String { "\(state)-\(cls)" }

    enum CodingKeys: String, CodingKey {
        case state, party, caucus, holder
        case cls = "class"
    }
}

struct DGroup: Codable, Identifiable, Hashable {
    let key: String
    let label: String
    let cvapShare: Double
    let turnout: Double
    let dem2p: Double            // baseline two-party Dem support among the group's voters
    var id: String { key }
}

struct DSeatsVotes: Codable {
    let swingRatio: Double
    let seatBias: Double
    let houseSize: Int
    enum CodingKeys: String, CodingKey {
        case swingRatio = "swing_ratio"
        case seatBias = "seat_bias"
        case houseSize = "house_size"
    }
}

struct Dataset: Codable {
    let states: [DState]
    let senateSeats: [DSenateSeat]
    let groups: [DGroup]
    let seatsVotes: DSeatsVotes
    let senateClassYears: [String: [Int]]
}

// MARK: - Election cycles

struct Cycle: Identifiable, Hashable {
    let year: Int
    let isPresidential: Bool
    let senateClass: Int           // which Senate class is up this cycle
    var id: Int { year }
    var label: String { String(year) }
    var kind: String { isPresidential ? "Presidential" : "Midterm" }
}

/// The cycles the simulator chains, in order. Class II:2026/2032, III:2028/2034, I:2030/2036.
let SIM_CYCLES: [Cycle] = [
    Cycle(year: 2026, isPresidential: false, senateClass: 2),
    Cycle(year: 2028, isPresidential: true,  senateClass: 3),
    Cycle(year: 2030, isPresidential: false, senateClass: 1),
    Cycle(year: 2032, isPresidential: true,  senateClass: 2),
    Cycle(year: 2034, isPresidential: false, senateClass: 3),
]

// MARK: - Composition snapshot

struct Composition: Hashable {
    var dem: Int = 0
    var rep: Int = 0
    var ind: Int = 0          // independents (shown separately; folded into caucus for control)
    var demCaucus: Int = 0    // dem + ind-who-caucus-dem
    var repCaucus: Int = 0

    var total: Int { dem + rep + ind }
    /// Senate majority needs 51 (VP breaks 50-50; we report the caucus split).
    func senateMajority() -> Party? {
        if demCaucus >= 51 { return .dem }
        if repCaucus >= 51 { return .rep }
        return nil   // 50-50, decided by the Vice President
    }
}
