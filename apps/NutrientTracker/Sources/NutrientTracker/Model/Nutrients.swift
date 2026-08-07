import Foundation

/// Role of a tracked nutrient in the coach.
enum NutrientRole: String, Codable {
    case gap        // a documented deficiency we try to CLOSE
    case watch      // already saturated by the meat diet; warn if intake is high
    case reference  // shown for context only (kcal, protein)
}

/// Canonical nutrient definition. `key` matches the keys used in logged-item
/// nutrient dictionaries and in the USDA snapshot mapping (see FoodDB).
struct NutrientDef: Identifiable, Hashable {
    let key: String
    let name: String
    let unit: String            // canonical display unit
    let role: NutrientRole
    var defaultTarget: Double?  // daily target (gap) — editable via Store overrides
    var upperLimit: Double?     // tolerable upper intake level (UL); nil = no established UL
    /// True when the UL applies only to supplemental/synthetic forms (folate, vit E,
    /// magnesium). For these, food intake is uncapped and only `.supplement`-sourced
    /// amounts count toward the ceiling — so a high-food day never false-alarms, and
    /// the floor (total target) and ceiling (supplemental UL) can coexist.
    var ulSupplementalOnly: Bool = false
    var docMagnitude: String?   // from the user's Gemini deficiency doc
    var docMissing: String?     // documented "amount missing"
    var recommends: [String]    // catalog item keys that cover this gap (from Deficency.md)
    var note: String?

    var id: String { key }

    /// Coarse severity from the deficiency doc, used to rank fixes. Severe ≫ moderate.
    var severityWeight: Int {
        guard let m = docMagnitude?.lowercased() else { return 0 }
        if m.contains("severe") { return 3 }
        if m.contains("moderate") { return 1 }
        return 0
    }
}

enum Nutrients {
    /// Seeded directly from the user's two docs (Nutrition.md / Deficency.md).
    static let all: [NutrientDef] = [
        // ---- gaps to close ----
        NutrientDef(key: "calcium", name: "Calcium", unit: "mg", role: .gap,
                    defaultTarget: 1000, upperLimit: 2500,
                    docMagnitude: "Severe", docMissing: "~750–850 mg",
                    recommends: ["sardines"],
                    note: "Muscle meat has ~zero calcium; dairy is intermittent."),
        NutrientDef(key: "manganese", name: "Manganese", unit: "mg", role: .gap,
                    defaultTarget: 2.3, upperLimit: 11,
                    docMagnitude: "Severe", docMissing: "~2.3 mg (≈ entire requirement)",
                    recommends: ["mussels", "mn_bisglycinate"],
                    note: "Animal products are very poor manganese sources."),
        NutrientDef(key: "vitC", name: "Vitamin C", unit: "mg", role: .gap,
                    defaultTarget: 90, upperLimit: 2000,
                    docMagnitude: "Moderate–Severe", docMissing: "~80–150 mg",
                    recommends: ["liver", "ascorbic_acid"],
                    note: "Trace only in fresh muscle meat; raw liver helps."),
        NutrientDef(key: "folate", name: "Folate", unit: "µg", role: .gap,
                    defaultTarget: 400, upperLimit: 1000, ulSupplementalOnly: true,
                    docMagnitude: "Moderate–Severe", docMissing: "~300–350 µg",
                    recommends: ["liver", "folate_mthf"],
                    note: "Liver is the primary animal source; else use 5-MTHF. "
                        + "UL (1000 µg) applies to supplemental folic acid, not food folate."),
        NutrientDef(key: "magnesium", name: "Magnesium", unit: "mg", role: .gap,
                    defaultTarget: 400, upperLimit: 350, ulSupplementalOnly: true,
                    docMagnitude: "Moderate", docMissing: "~200–250 mg",
                    recommends: ["mag_bisglycinate"],
                    note: "Depleted further by 2-hr training; Bisglycinate form. "
                        + "UL (350 mg) is for supplemental magnesium only; food is uncapped."),
        NutrientDef(key: "vitE", name: "Vitamin E", unit: "mg", role: .gap,
                    defaultTarget: 15, upperLimit: 1000, ulSupplementalOnly: true,
                    docMagnitude: "Moderate", docMissing: "~10–15 mg",
                    recommends: ["tocopherol"],
                    note: "Low in grain-fed ruminant/pork. "
                        + "UL (1000 mg) applies to supplemental alpha-tocopherol."),
        NutrientDef(key: "omega3", name: "Omega-3 (EPA+DHA)", unit: "mg", role: .gap,
                    defaultTarget: 1500, upperLimit: 3000,
                    docMagnitude: "Moderate", docMissing: "~1–2 g",
                    recommends: ["sardines"],
                    note: "Balances the pro-inflammatory omega-6 load. "
                        + "No formal UL; soft ceiling ~3 g/day combined EPA+DHA (FDA GRAS)."),
        NutrientDef(key: "vitD", name: "Vitamin D", unit: "µg", role: .gap,
                    defaultTarget: 50, upperLimit: 100,   // 50 µg = 2000 IU
                    docMagnitude: "Variable (Moderate)", docMissing: "~2,000–5,000 IU",
                    recommends: ["sardines", "d3_k2"],
                    note: "≈ absent from food without sun; 1 µg = 40 IU."),
        NutrientDef(key: "vitK2", name: "Vitamin K2 (MK-7)", unit: "µg", role: .gap,
                    defaultTarget: 100, upperLimit: nil,
                    docMagnitude: "Variable (Moderate)", docMissing: "~100 µg",
                    recommends: ["d3_k2"],
                    note: "Food gives some MK-4; MK-7 comes from the supplement."),
        // ---- saturated / toxicity-watch ----
        NutrientDef(key: "iron", name: "Iron", unit: "mg", role: .watch,
                    defaultTarget: nil, upperLimit: 45,
                    docMagnitude: nil, docMissing: nil, recommends: [],
                    note: "Saturated by heme iron from beef — avoid extra (overload risk)."),
        NutrientDef(key: "zinc", name: "Zinc", unit: "mg", role: .watch,
                    defaultTarget: nil, upperLimit: 40,
                    docMagnitude: nil, docMissing: nil, recommends: [],
                    note: "Saturated by beef — extra triggers zinc/copper imbalance."),
        NutrientDef(key: "vitA", name: "Vitamin A", unit: "µg", role: .watch,
                    defaultTarget: nil, upperLimit: 3000,
                    docMagnitude: nil, docMissing: nil, recommends: [],
                    note: "Watch with liver intake — preformed A accumulates."),
        NutrientDef(key: "vitB12", name: "Vitamin B12", unit: "µg", role: .watch,
                    defaultTarget: nil, upperLimit: nil,
                    docMagnitude: nil, docMissing: nil, recommends: [],
                    note: "Completely saturated by meat."),
        // ---- reference ----
        NutrientDef(key: "kcal", name: "Energy", unit: "kcal", role: .reference,
                    defaultTarget: nil, upperLimit: nil, docMagnitude: nil,
                    docMissing: nil, recommends: [], note: nil),
        NutrientDef(key: "protein", name: "Protein", unit: "g", role: .reference,
                    defaultTarget: nil, upperLimit: nil, docMagnitude: nil,
                    docMissing: nil, recommends: [], note: nil),
    ]

    static let byKey: [String: NutrientDef] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    static var gaps: [NutrientDef] { all.filter { $0.role == .gap } }
    static var watch: [NutrientDef] { all.filter { $0.role == .watch } }

    static func name(_ key: String) -> String { byKey[key]?.name ?? key }
    static func unit(_ key: String) -> String { byKey[key]?.unit ?? "" }
}
