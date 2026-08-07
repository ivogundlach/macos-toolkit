import Foundation
import Combine

private struct PersistedState: Codable {
    var items: [LoggedItem] = []
    var symptoms: [SymptomEntry] = []
    var profile: Profile = Profile()
    var targets: [String: Double] = [:]
    var catalog: [CatalogItem] = Catalog.seed
}

// Forward-compatible decode: missing keys fall back to defaults instead of
// throwing. Swift's synthesized Codable does NOT honor property defaults for
// absent keys, so adding a future field would otherwise make every older
// store.json fail to decode and lose data. Declared in an extension so the
// memberwise initializer used by save() is preserved.
private extension PersistedState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([LoggedItem].self, forKey: .items) ?? []
        symptoms = try c.decodeIfPresent([SymptomEntry].self, forKey: .symptoms) ?? []
        profile = try c.decodeIfPresent(Profile.self, forKey: .profile) ?? Profile()
        targets = try c.decodeIfPresent([String: Double].self, forKey: .targets) ?? [:]
        catalog = try c.decodeIfPresent([CatalogItem].self, forKey: .catalog) ?? Catalog.seed
    }
}

/// Single source of app state. Transient UI state lives in ObservableObject
/// view-models instead of direct `@State` properties.
final class Store: ObservableObject {
    @Published var items: [LoggedItem]
    @Published var symptoms: [SymptomEntry]
    @Published var profile: Profile
    @Published var targets: [String: Double]
    @Published var catalog: [CatalogItem]

    let foodDB = FoodDB()
    private let url: URL

    init() {
        #if IVO_PREVIEW
        // Compile-time-only QA state: never resolves or creates Application
        // Support, and save() is a no-op below. The release build omits this
        // branch and keeps the existing JSON persistence path unchanged.
        self.url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NutrientTrackerPreviewFixture.json")
        let fixture = Self.previewState()
        items = fixture.items
        symptoms = fixture.symptoms
        profile = fixture.profile
        targets = fixture.targets
        catalog = fixture.catalog
        return
        #else
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NutrientTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("store.json")

        let loaded: PersistedState?
        if let data = try? Data(contentsOf: url) {
            if let s = try? JSONDecoder().decode(PersistedState.self, from: data) {
                loaded = s
            } else {
                // File exists but won't decode (genuine corruption). Preserve it
                // before any save() can overwrite it with empty state.
                let backup = dir.appendingPathComponent(
                    "store.corrupt-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: url, to: backup)
                loaded = nil
            }
        } else {
            loaded = nil   // first run: no file yet
        }

        if let s = loaded {
            items = s.items; symptoms = s.symptoms; profile = s.profile
            targets = s.targets
            catalog = Self.mergedCatalog(saved: s.catalog)
        } else {
            items = []; symptoms = []; profile = Profile()
            targets = [:]; catalog = Catalog.seed
        }

        if ProcessInfo.processInfo.environment["NT_DEBUG"] != nil {
            debugLog("foodDB.isOpen=\(foodDB.isOpen) store=\(url.path)")
            auditRecommends()
        }
        #endif
    }

    func save() {
        #if IVO_PREVIEW
        return
        #else
        let s = PersistedState(items: items, symptoms: symptoms, profile: profile,
                               targets: targets, catalog: catalog)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(s) { try? data.write(to: url, options: .atomic) }
        #endif
    }

    // MARK: logging
    /// A catalog item's actual nutrient contribution: USDA snapshot at the default
    /// serving for animal fixes, or the explicit per-dose payload for supplements.
    func payload(of item: CatalogItem) -> [String: Double] {
        if item.kind == .animalFix, let fdc = item.fdcId {
            return foodDB.snapshot(fdcId: fdc, grams: item.defaultGrams ?? 100)
        }
        return item.dose ?? [:]
    }

    func logCatalog(_ item: CatalogItem, on date: Date) {
        let nutrients = payload(of: item)
        guard !nutrients.isEmpty else { return }
        let source: LoggedItem.Source =
            (item.kind == .animalFix && item.fdcId != nil) ? .animalFix : .supplement
        items.append(LoggedItem(date: date, name: item.name, source: source,
                                fdcId: item.fdcId, grams: item.defaultGrams,
                                catalogKey: item.key, nutrients: nutrients))
        save()
    }

    func logUSDA(_ hit: FoodHit, grams: Double, on date: Date) {
        guard grams.isFinite, grams > 0 else { return }
        let nutrients = foodDB.snapshot(fdcId: hit.fdcId, grams: grams)
        guard !nutrients.isEmpty else { return }
        items.append(LoggedItem(date: date, name: shortName(hit.description),
                                source: .usda, fdcId: hit.fdcId, grams: grams,
                                catalogKey: nil, nutrients: nutrients))
        save()
    }

    func remove(_ item: LoggedItem) { items.removeAll { $0.id == item.id }; save() }

    // MARK: symptoms
    func addSymptom(_ s: SymptomEntry) { symptoms.append(s); save() }
    func remove(_ s: SymptomEntry) { symptoms.removeAll { $0.id == s.id }; save() }

    // MARK: targets
    func target(for def: NutrientDef) -> Double { targets[def.key] ?? def.defaultTarget ?? 0 }
    func setTarget(_ v: Double, for def: NutrientDef) {
        guard v.isFinite, v > 0 else { targets.removeValue(forKey: def.key); save(); return }
        targets[def.key] = v
        save()
    }
    func resetTargets() { targets = [:]; save() }

    // MARK: derived
    func gaps(on day: Date) -> [GapResult] {
        Engine.gaps(Engine.items(items, on: day), targets: effectiveTargets())
    }
    func watches(on day: Date) -> [WatchResult] { Engine.watches(Engine.items(items, on: day)) }
    func correlations() -> [FoodSymptomStat] {
        Engine.correlations(items: items, symptoms: symptoms,
                            windowHours: profile.correlationWindowHours)
    }
    /// Long-term (habitual) status per nutrient over a trailing window of `days`.
    func chronic(days: Int) -> (rows: [ChronicRow], loggedDays: Int, windowDays: Int) {
        Engine.chronic(items, targets: effectiveTargets(), days: days)
    }

    /// Recommendations driven by HABITUAL shortfall over the window, not today's
    /// plate: a gap is "open" when average intake per logged day is below target,
    /// and ceilings are checked against habitual UL-relevant intake. This is the
    /// app's primary recommender — the medium/long-term philosophy.
    func chronicRecommendations(days: Int) -> [Recommendation] {
        let c = chronic(days: days)
        guard c.loggedDays > 0 else { return [] }
        let openGaps: [GapResult] = c.rows.compactMap { r in
            guard let target = r.target, target > 0 else { return nil }
            return GapResult(def: r.def, total: r.perLoggedDay, target: target)
        }
        let ulTotals = Dictionary(uniqueKeysWithValues:
            c.rows.map { ($0.def.key, $0.ceilingPerLoggedDay) })
        let payloads = Dictionary(uniqueKeysWithValues: catalog.map { ($0.key, payload(of: $0)) })
        return Engine.recommendations(forOpen: openGaps, catalog: catalog,
                                      payloads: payloads, ulTotals: ulTotals)
    }

    private func effectiveTargets() -> [String: Double] {
        var t: [String: Double] = [:]
        for def in Nutrients.gaps { t[def.key] = target(for: def) }
        return t
    }

    private func shortName(_ desc: String) -> String {
        // "Beef, ground, 80% lean meat / 20% fat, cooked" -> first 3 comma parts
        desc.split(separator: ",").prefix(3).joined(separator: ",")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func mergedCatalog(saved: [CatalogItem]) -> [CatalogItem] {
        guard !saved.isEmpty else { return Catalog.seed }
        let savedByKey = Dictionary(uniqueKeysWithValues: saved.map { ($0.key, $0) })
        var out = Catalog.seed.map { savedByKey[$0.key] ?? $0 }
        let seedKeys = Set(Catalog.seed.map(\.key))
        out.append(contentsOf: saved.filter { !seedKeys.contains($0.key) })
        return out
    }

    #if IVO_PREVIEW
    /// Representative, in-memory-only coverage for root visual/interaction QA.
    /// Dates span every 30/90/365 selector while today's entries populate Log.
    private static func previewState() -> PersistedState {
        let calendar = Calendar.current
        func date(daysAgo: Int, hour: Int) -> Date {
            let shifted = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: shifted) ?? shifted
        }

        let entries: [LoggedItem] = [
            LoggedItem(date: date(daysAgo: 0, hour: 8),
                       name: "Sardines, canned with bone", source: .animalFix,
                       fdcId: 175139, grams: 100, catalogKey: "sardines",
                       nutrients: ["kcal": 185, "protein": 24, "calcium": 382,
                                   "omega3": 1480, "vitD": 12, "vitB12": 8.9,
                                   "iron": 2.9, "zinc": 1.3]),
            LoggedItem(date: date(daysAgo: 0, hour: 9),
                       name: "Magnesium Bisglycinate", source: .supplement,
                       fdcId: nil, grams: nil, catalogKey: "mag_bisglycinate",
                       nutrients: ["magnesium": 200]),
            LoggedItem(date: date(daysAgo: 3, hour: 13),
                       name: "Beef, ground, cooked", source: .usda,
                       fdcId: 174036, grams: 220, catalogKey: nil,
                       nutrients: ["kcal": 560, "protein": 57, "iron": 6.1,
                                   "zinc": 12.4, "vitB12": 6.0, "magnesium": 46]),
            LoggedItem(date: date(daysAgo: 12, hour: 18),
                       name: "Beef liver, pan-fried", source: .animalFix,
                       fdcId: 168627, grams: 100, catalogKey: "liver",
                       nutrients: ["kcal": 175, "protein": 26, "folate": 260,
                                   "vitC": 23, "vitA": 9442, "iron": 6.5,
                                   "vitB12": 70]),
            LoggedItem(date: date(daysAgo: 38, hour: 12),
                       name: "Blue mussels, cooked", source: .animalFix,
                       fdcId: 174217, grams: 100, catalogKey: "mussels",
                       nutrients: ["kcal": 172, "protein": 24, "manganese": 6.8,
                                   "iron": 6.7, "vitB12": 24, "omega3": 700]),
            LoggedItem(date: date(daysAgo: 82, hour: 8),
                       name: "Liquid D3 + K2", source: .supplement,
                       fdcId: nil, grams: nil, catalogKey: "d3_k2",
                       nutrients: ["vitD": 50, "vitK2": 100]),
            LoggedItem(date: date(daysAgo: 180, hour: 10),
                       name: "Ascorbic Acid powder", source: .supplement,
                       fdcId: nil, grams: nil, catalogKey: "ascorbic_acid",
                       nutrients: ["vitC": 500])
        ]

        let episodes: [SymptomEntry] = [
            SymptomEntry(date: date(daysAgo: 0, hour: 12),
                         kinds: ["Bloating", "Gas"], severity: 3,
                         note: "After breakfast"),
            SymptomEntry(date: date(daysAgo: 3, hour: 20),
                         kinds: ["Cramps"], severity: 4,
                         note: "Evening training"),
            SymptomEntry(date: date(daysAgo: 12, hour: 22),
                         kinds: ["Reflux/Heartburn"], severity: 2,
                         note: "Mild and brief")
        ]

        return PersistedState(
            items: entries,
            symptoms: episodes,
            profile: Profile(),
            targets: ["magnesium": 420],
            catalog: Catalog.seed
        )
    }
    #endif

    private func debugLog(_ msg: String) {
        FileHandle.standardError.write(Data("NT_DEBUG: \(msg)\n".utf8))
    }

    /// Dev-only (NT_DEBUG): the authored `recommends` lists on each gap are a
    /// curation allowlist, kept by hand. This flags drift — a recommended catalog
    /// key that is missing or that delivers none of the nutrient it's listed for.
    private func auditRecommends() {
        let byKey = Dictionary(uniqueKeysWithValues: catalog.map { ($0.key, $0) })
        for def in Nutrients.gaps {
            for key in def.recommends {
                guard let item = byKey[key] else {
                    debugLog("recommends \(def.key) -> missing catalog '\(key)'"); continue
                }
                if (payload(of: item)[def.key] ?? 0) <= 0 {
                    debugLog("recommends '\(key)' listed for \(def.key) but provides 0")
                }
            }
        }
    }
}
