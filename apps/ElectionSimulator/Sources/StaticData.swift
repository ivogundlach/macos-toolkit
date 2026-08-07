import Foundation

/// Decodes the embedded dataset once and exposes typed lookups.
enum Static {
    static let dataset: Dataset = {
        let data = Data(GeneratedData.datasetJSON.utf8)
        do { return try JSONDecoder().decode(Dataset.self, from: data) }
        catch { fatalError("dataset decode failed: \(error)") }
    }()

    static var states: [DState] { dataset.states }
    static var votingStates: [DState] { dataset.states.filter { $0.isVotingState } }
    static var senateSeats: [DSenateSeat] { dataset.senateSeats }
    static var groups: [DGroup] { dataset.groups }
    static var seatsVotes: DSeatsVotes { dataset.seatsVotes }

    static let byCode: [String: DState] = Dictionary(
        uniqueKeysWithValues: dataset.states.map { ($0.code, $0) })

    static func state(_ code: String) -> DState? { byCode[code] }
    static func name(_ code: String) -> String { byCode[code]?.name ?? code }

    /// Senate seats of a given class, in state order.
    static func seats(inClass cls: Int) -> [DSenateSeat] {
        senateSeats.filter { $0.cls == cls }.sorted { $0.state < $1.state }
    }
}
