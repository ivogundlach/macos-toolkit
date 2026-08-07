import Foundation

struct AIInsightsReport: Decodable {
    struct Action: Decodable, Identifiable {
        let id: String
        let title: String
        let detail: String
    }

    struct Finding: Decodable, Identifiable {
        var id: String { title + evidence.joined() }
        let title: String
        let interpretation: String
        let evidence: [String]
        let actions: [Action]
    }

    struct Window: Decodable {
        let window: String
        let confidence: Double
        let source_start: String
        let source_end: String
        let summary: String
        let findings: [Finding]
    }

    let schema: Int
    let generated_at: String
    let model: String
    let windows: [Window]

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/vitals/findings/latest.json")

    static func load() -> AIInsightsReport? {
        guard let data = try? Data(contentsOf: url),
              data.count <= 32 * 1024,
              let report = try? JSONDecoder().decode(AIInsightsReport.self, from: data),
              report.schema == 1 else { return nil }
        return report
    }

    func section(for window: HistoryWindow) -> Window? {
        windows.first { $0.window == window.rawValue }
    }

    var generatedLabel: String {
        guard let date = ISO8601DateFormatter().date(from: generated_at) else { return "cached" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
