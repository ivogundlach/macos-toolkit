import Foundation

struct GapResult: Identifiable {
    let def: NutrientDef
    let total: Double
    let target: Double
    var remaining: Double { max(0, target - total) }
    var pct: Double { target <= 0 ? 1 : min(1, total / target) }
    var id: String { def.key }
}

struct WatchResult: Identifiable {
    let def: NutrientDef
    let total: Double
    var overLimit: Bool { if let ul = def.upperLimit { return total > ul }; return false }
    var id: String { def.key }
}

/// One open gap a recommended item addresses, with how much it actually delivers.
struct GapCoverage {
    let def: NutrientDef
    let amount: Double       // this item's contribution toward the gap nutrient
    let remaining: Double    // how much of the gap was still open before adding it
    var fillPct: Double { remaining <= 0 ? 1 : min(1, amount / remaining) }
}

/// A watch nutrient that this item would push over its upper limit if added.
struct LimitWarning: Identifiable {
    let def: NutrientDef
    let projected: Double     // watch-nutrient total if this item is added today
    let limit: Double
    var id: String { def.key }
}

struct Recommendation: Identifiable {
    let item: CatalogItem
    let covers: [GapCoverage]      // open gaps this intervention addresses, with amounts
    let warnings: [LimitWarning]   // watch nutrients it would push over limit
    var id: String { item.key }
    var severityScore: Int { covers.reduce(0) { $0 + $1.def.severityWeight } }
}

struct FoodSymptomStat: Identifiable {
    let food: String
    let eaten: Int
    let followed: Int                 // times followed by ≥1 symptom in window
    let breakdown: [String: Int]      // symptom kind -> count
    var rate: Double { eaten == 0 ? 0 : Double(followed) / Double(eaten) }
    var id: String { food }
    var topSymptoms: [String] {
        breakdown.sorted { $0.value > $1.value }.prefix(3).map {
            "\($0.key) ×\($0.value)"
        }
    }
}

/// One nutrient's long-term (habitual) status over a trailing window: average
/// intake per logged day, against its deficiency target (floor) and upper limit
/// (ceiling). The ceiling uses UL-relevant intake (supplemental-only where that
/// applies), so chronic over-supplementation is caught even when the daily view
/// would miss slow accumulation of fat-soluble vitamins and iron.
struct ChronicRow: Identifiable {
    let def: NutrientDef
    let perLoggedDay: Double          // avg total intake on days with any log
    let ceilingPerLoggedDay: Double   // avg UL-relevant intake on logged days
    let target: Double?               // floor (gap nutrients); nil for watch-only
    var id: String { def.key }
    var floorPct: Double? { guard let t = target, t > 0 else { return nil }; return perLoggedDay / t }
    var ceilingPct: Double? { guard let l = def.upperLimit, l > 0 else { return nil }
        return ceilingPerLoggedDay / l }
}

enum Engine {
    private static var cal: Calendar { Calendar.current }

    static func sameDay(_ a: Date, _ b: Date) -> Bool { cal.isDate(a, inSameDayAs: b) }

    static func items(_ all: [LoggedItem], on day: Date) -> [LoggedItem] {
        all.filter { sameDay($0.date, day) }
    }

    static func totals(_ items: [LoggedItem]) -> [String: Double] {
        var t: [String: Double] = [:]
        for it in items { for (k, v) in it.nutrients { t[k, default: 0] += v } }
        return t
    }

    static func gaps(_ items: [LoggedItem], targets: [String: Double]) -> [GapResult] {
        let t = totals(items)
        return Nutrients.gaps.map { def in
            let target = targets[def.key] ?? def.defaultTarget ?? 0
            return GapResult(def: def, total: t[def.key] ?? 0, target: target)
        }
    }

    static func watches(_ items: [LoggedItem]) -> [WatchResult] {
        let t = totals(items)
        return Nutrients.watch.map { WatchResult(def: $0, total: t[$0.key] ?? 0) }
    }

    /// Interventions that cover gaps still open today. `payloads` is each catalog
    /// item's actual nutrient contribution (supplement dose, or USDA snapshot at the
    /// default serving); `ulTotals` is today's UL-relevant intake of every nutrient
    /// that has an upper limit (see `ulIntake`). Ranked by severity-weighted coverage,
    /// then breadth, then food-over-pill, then key (a stable final tiebreak so order
    /// never flips between runs).
    static func recommendations(forOpen gaps: [GapResult], catalog: [CatalogItem],
                                payloads: [String: [String: Double]],
                                ulTotals: [String: Double]) -> [Recommendation] {
        let openGaps = gaps.filter { $0.remaining > 0 }
        guard !openGaps.isEmpty else { return [] }
        let byKey = Dictionary(uniqueKeysWithValues: catalog.map { ($0.key, $0) })

        var coverage: [String: [GapCoverage]] = [:]   // catalogKey -> covered open gaps
        for g in openGaps {
            for catKey in g.def.recommends where byKey[catKey] != nil {
                let amount = payloads[catKey]?[g.def.key] ?? 0
                coverage[catKey, default: []].append(
                    GapCoverage(def: g.def, amount: amount, remaining: g.remaining))
            }
        }

        let recs: [Recommendation] = coverage.compactMap { catKey, covers in
            guard let item = byKey[catKey] else { return nil }
            let itemIsSupplement = (item.kind == .supplement)
            // Warn for ANY nutrient with a UL, not just `.watch` ones — a fix that
            // also delivers calcium/vit A/vit D etc. can breach a ceiling too.
            let warnings: [LimitWarning] = Nutrients.all.compactMap { def in
                guard let limit = def.upperLimit else { return nil }
                // Supplemental-only ceilings ignore food (animal-fix) contributions.
                guard !def.ulSupplementalOnly || itemIsSupplement else { return nil }
                let added = payloads[catKey]?[def.key] ?? 0
                guard added > 0 else { return nil }
                let projected = (ulTotals[def.key] ?? 0) + added
                return projected > limit
                    ? LimitWarning(def: def, projected: projected, limit: limit) : nil
            }
            return Recommendation(item: item, covers: covers, warnings: warnings)
        }

        return recs.sorted { a, b in
            if a.severityScore != b.severityScore { return a.severityScore > b.severityScore }
            if a.covers.count != b.covers.count { return a.covers.count > b.covers.count }
            let aFix = a.item.kind == .animalFix, bFix = b.item.kind == .animalFix
            if aFix != bFix { return aFix }
            return a.item.key < b.item.key
        }
    }

    /// For each food eaten, how often a GI symptom followed within the window.
    /// Grouped by a stable identity (USDA fdcId, else catalog key, else name) so two
    /// distinct foods that shorten to the same name don't merge. Note: a symptom is
    /// counted for EVERY food in its window — this is association, not attribution.
    static func correlations(items: [LoggedItem], symptoms: [SymptomEntry],
                             windowHours: Double) -> [FoodSymptomStat] {
        let window = windowHours * 3600
        func key(_ it: LoggedItem) -> String {
            if let f = it.fdcId { return "fdc:\(f)" }
            if let c = it.catalogKey { return "cat:\(c)" }
            return "name:\(it.name)"
        }
        var names: [String: String] = [:]
        var eaten: [String: Int] = [:]
        var followed: [String: Int] = [:]
        var breakdown: [String: [String: Int]] = [:]
        let sorted = symptoms.sorted { $0.date < $1.date }
        for it in items {
            let k = key(it)
            names[k] = it.name
            eaten[k, default: 0] += 1
            let following = sorted.filter { $0.date > it.date && $0.date <= it.date + window }
            if !following.isEmpty {
                followed[k, default: 0] += 1
                for s in following {
                    for kind in s.kinds { breakdown[k, default: [:]][kind, default: 0] += 1 }
                }
            }
        }
        return eaten.map { k, n in
            FoodSymptomStat(food: names[k] ?? k, eaten: n,
                            followed: followed[k] ?? 0,
                            breakdown: breakdown[k] ?? [:])
        }
        .sorted { a, b in
            if a.rate != b.rate { return a.rate > b.rate }
            if a.eaten != b.eaten { return a.eaten > b.eaten }
            return a.food < b.food
        }
    }

    /// Per-nutrient intake that counts toward each upper limit. Supplemental-only
    /// ceilings (folate, vit E, magnesium) count only `.supplement`-sourced amounts;
    /// food intake of those is uncapped and excluded.
    static func ulIntake(_ items: [LoggedItem]) -> [String: Double] {
        var out: [String: Double] = [:]
        for def in Nutrients.all where def.upperLimit != nil {
            var sum = 0.0
            for it in items where !def.ulSupplementalOnly || it.source == .supplement {
                sum += it.nutrients[def.key] ?? 0
            }
            out[def.key] = sum
        }
        return out
    }

    /// Long-term status over the trailing `days` calendar days. Intake is averaged
    /// over the days actually logged (not calendar days) so an intermittent logger
    /// gets "your typical logged day," not a figure diluted by empty days. The
    /// returned `loggedDays`/`windowDays` lets the UI show how representative it is.
    static func chronic(_ all: [LoggedItem], targets: [String: Double], days: Int)
        -> (rows: [ChronicRow], loggedDays: Int, windowDays: Int) {
        let today = cal.startOfDay(for: .now)
        let start = cal.date(byAdding: .day, value: -(days - 1), to: today)!
        let end = cal.date(byAdding: .day, value: 1, to: today)!      // start of tomorrow
        let win = all.filter { $0.date >= start && $0.date < end }
        let loggedDays = Set(win.map { cal.startOfDay(for: $0.date) }).count
        let denom = Double(max(1, loggedDays))

        let total = totals(win)
        let ceil = ulIntake(win)
        let rows = Nutrients.all.filter { $0.role != .reference }.map { def in
            ChronicRow(def: def,
                       perLoggedDay: (total[def.key] ?? 0) / denom,
                       ceilingPerLoggedDay: (ceil[def.key] ?? 0) / denom,
                       target: def.role == .gap ? (targets[def.key] ?? def.defaultTarget) : nil)
        }
        return (rows, loggedDays, days)
    }

    /// Daily coverage % of a gap nutrient over the last `days` days (for charts).
    static func dailyCoverage(_ all: [LoggedItem], key: String, target: Double,
                              days: Int) -> [(date: Date, pct: Double)] {
        guard target > 0 else { return [] }
        let today = cal.startOfDay(for: .now)
        return (0..<days).reversed().map { offset in
            let day = cal.date(byAdding: .day, value: -offset, to: today)!
            let total = items(all, on: day).reduce(0.0) { $0 + ($1.nutrients[key] ?? 0) }
            return (day, min(1, total / target))
        }
    }

    static func symptomCount(_ symptoms: [SymptomEntry], days: Int) -> [(date: Date, n: Int)] {
        let today = cal.startOfDay(for: .now)
        return (0..<days).reversed().map { offset in
            let day = cal.date(byAdding: .day, value: -offset, to: today)!
            return (day, symptoms.filter { sameDay($0.date, day) }.count)
        }
    }
}
