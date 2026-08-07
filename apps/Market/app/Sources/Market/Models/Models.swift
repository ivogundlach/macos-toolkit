import Foundation

// Domain models mapped from SQLite rows (CONTRACTS.md §2) and appctl payloads.
// All decimal money/quantity stay as Strings (CONTRACTS.md conventions) — Swift
// never does arithmetic on them.

struct Regime: Identifiable {
    var id: String { sessionDate }
    let sessionDate: String
    let capturedAt: String
    let vix: Double?
    let vixTrend5d: Double?
    let fearGreed: Double?
    let putCall: Double?
    let oiNote: String?
    let score: Double?       // bull/bear score 0..100
    let confidence: String?

    /// Coarse label from score. 0 = max bearish, 100 = max bullish.
    var label: String {
        guard let s = score else { return "Unknown" }
        switch s {
        case ..<35: return "Bearish"
        case 35..<45: return "Cautious"
        case 45..<55: return "Neutral"
        case 55..<65: return "Constructive"
        default: return "Bullish"
        }
    }
}

struct TrackRow: Identifiable {
    var id: String { ticker }
    let ticker: String
    let track: String        // growth | value | dividends
    let status: String       // active | exited | conflict
    let conviction: Double
    let enteredAt: String?
    let lastSignalAt: String?
    let exitedAt: String?
    let exitReason: String?
    let source: String?      // 'model' | 'override' (derived_state only)
}

struct Signal: Identifiable {
    var id: String { signalId }
    let signalId: String
    let runId: String
    let sessionDate: String
    let ticker: String
    let direction: String    // bullish | bearish
    let strength: String     // strong | moderate | weak
    let bestRank: Int
    let originKey: String    // pipe-joined distinct origin keys
    let trackProposal: String
    let eventIds: [String]

    /// Distinct voices = distinct origin keys (CONTRACTS view spec for signals).
    var voices: Int {
        Set(originKey.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }).count
    }
    var sources: [String] {
        originKey.split(separator: "|").map { String($0.split(separator: ":").first ?? $0) }
    }
}

/// Deterministic bullishness ranking for the Ticker detail default list.
/// `score` > 0 leans bullish, < 0 leans bearish; ties broken by ticker.
struct TickerScore: Identifiable {
    var id: String { ticker }
    let ticker: String
    let score: Double
    let bullish: Int    // count of bullish signals in latest session
    let bearish: Int    // count of bearish signals in latest session
    let conviction: Double?

    var lean: String {
        if score > 0.05 { return "Bullish" }
        if score < -0.05 { return "Bearish" }
        return "Neutral"
    }
}

struct EventRow: Identifiable {
    var id: String { eventId }
    let eventId: String
    let ts: String
    let sessionDate: String
    let source: String
    let rank: Int
    let author: String
    let type: String
    let text: String
    let tickers: [String]
    let urls: [String]
}

struct RunRow: Identifiable {
    var id: String { runId }
    let runId: String
    let startedAt: String
    let committedAt: String?
    let kind: String
    let watermark: String?
    let manifest: String      // raw JSON string
}

/// Full debrief content from runs_debrief.debrief_json (schema v4). The app is
/// the sole debrief surface since 2026-07-01 (email delivery retired).
struct DebriefContent {
    struct RankSection: Identifiable {
        var id: Int { rank }
        let rank: Int
        let summary: String
    }
    let date: String
    let headline: String
    let summary: String        // market_summary
    let watchNotes: String
    let byRank: [RankSection]
    let degraded: Bool
    let sessionLabel: String
}

struct TransitionRow: Identifiable {
    let id: Int64
    let runId: String
    let sessionDate: String
    let ticker: String
    let transition: String
    let detail: String
}

struct ConvictionPoint: Identifiable {
    var id: String { runId }
    let runId: String
    let sessionDate: String
    let track: String?
    let conviction: Double
}

struct Position: Identifiable {
    let id: Int64
    let symbol: String
    let quantity: String      // decimal text
    let costBasis: String?
    let currency: String
    let account: String?
    let provenance: String    // manual | scrape
    let openedAt: String?
    let updatedAt: String
}

struct Watchlist: Identifiable {
    let id: Int64
    let name: String
    let kind: String          // candidate | holding
    let tickers: [String]
    let provenance: String
    let stale: Bool
    let updatedAt: String
}

/// One row of the indicator-suite status plane (schema v5, indicator_status).
/// A deterministic readout of a stock's Arch/Helix state on a timeframe — NOT the
/// LLM conviction score. `state` is bullish (green) / bearish (purple) / neutral.
struct IndicatorStatusRow: Identifiable {
    var id: String { "\(ticker)|\(indicator)|\(timeframe)" }
    let ticker: String
    let indicator: String        // arch | helix | ...
    let timeframe: String        // 1W | 1D | ... | "" when unknown
    let state: String            // bullish | bearish | neutral
    let previousState: String?   // state before the most recent change
    let changedAt: String?       // ts the current state was entered
    let lastReadAt: String       // ts of the most recent reading
    let detail: String           // raw JSON (phase, zero-side, alert text)
    let readCount: Int

    /// Phase (early/late) pulled from the detail JSON, if present.
    var phase: String? {
        guard let data = detail.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let p = obj["phase"] as? String else { return nil }
        return p
    }
    var dateChanged: String { String((changedAt ?? lastReadAt).prefix(10)) }
}

/// meta table view + schema-compat gate (CONTRACTS.md §4/§5).
struct Meta {
    let schemaVersion: Int
    let minSupported: Int
    let maxSupported: Int
    let generation: Int?

    // The Swift app understands schema v2.
    static let appSchema = 2

    /// True if the app can safely read this DB.
    var compatible: Bool {
        schemaVersion >= minSupported && schemaVersion <= maxSupported
            && Meta.appSchema >= minSupported && Meta.appSchema <= maxSupported
    }
}
