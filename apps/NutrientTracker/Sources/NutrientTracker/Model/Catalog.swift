import Foundation

enum CatalogKind: String, Codable { case animalFix, supplement }

/// A quick-add intervention from the user's Deficency.md protocol.
/// Animal fixes resolve their nutrients from the USDA DB (by fdcId × grams).
/// Supplements carry an explicit per-dose nutrient payload (editable).
struct CatalogItem: Identifiable, Codable, Hashable {
    var key: String
    var name: String
    var kind: CatalogKind
    var detail: String              // form / dose note (bioavailability mandate)
    var fdcId: Int?                 // animal fixes
    var defaultGrams: Double?       // animal fixes
    var dose: [String: Double]?     // supplements: canonical nutrient key -> amount
    var doseLabel: String?          // e.g. "1 serving", "5 drops"

    var id: String { key }
}

enum Catalog {
    /// Seeded from Deficency.md (the cost/calorie-efficient protocol).
    static let seed: [CatalogItem] = [
        // ---- animal-based fixes (resolved against USDA) ----
        CatalogItem(key: "sardines", name: "Sardines, canned w/ bone",
                    kind: .animalFix,
                    detail: "Bone-in, in water. Calcium + Omega-3 + D3 in one. ~150 kcal/tin.",
                    fdcId: 175139, defaultGrams: 100, dose: nil, doseLabel: "100 g"),
        CatalogItem(key: "liver", name: "Beef liver, pan-fried",
                    kind: .animalFix,
                    detail: "Folate + Vitamin C. Cook lightly; ~130 kcal/100g.",
                    fdcId: 168627, defaultGrams: 100, dose: nil, doseLabel: "100 g"),
        CatalogItem(key: "mussels", name: "Blue mussels, cooked",
                    kind: .animalFix,
                    detail: "Only strong animal source of manganese. ~85 kcal/100g.",
                    fdcId: 174217, defaultGrams: 100, dose: nil, doseLabel: "100 g"),
        // ---- supplements (bioavailable forms only, per the mandate) ----
        CatalogItem(key: "mag_bisglycinate", name: "Magnesium Bisglycinate",
                    kind: .supplement, detail: "Glycinate only — reject oxide. Bulk powder.",
                    fdcId: nil, defaultGrams: nil,
                    dose: ["magnesium": 200], doseLabel: "200 mg elemental"),
        CatalogItem(key: "d3_k2", name: "Liquid D3 + K2 (MK-7)",
                    kind: .supplement, detail: "Cholecalciferol in oil + MK-7 all-trans. Sublingual.",
                    fdcId: nil, defaultGrams: nil,
                    dose: ["vitD": 50, "vitK2": 100], doseLabel: "2000 IU D3 + 100 µg K2"),
        CatalogItem(key: "ascorbic_acid", name: "Ascorbic Acid powder",
                    kind: .supplement, detail: "Bulk vitamin C. Pennies/dose, zero calories.",
                    fdcId: nil, defaultGrams: nil,
                    dose: ["vitC": 500], doseLabel: "500 mg"),
        CatalogItem(key: "tocopherol", name: "Alpha-Tocopherol drops",
                    kind: .supplement, detail: "Vitamin E. Meets 15 mg without calorie cost.",
                    fdcId: nil, defaultGrams: nil,
                    dose: ["vitE": 15], doseLabel: "15 mg"),
        CatalogItem(key: "mn_bisglycinate", name: "Manganese Bisglycinate",
                    kind: .supplement, detail: "Bisglycinate or ground-clove hack — reject sulfate.",
                    fdcId: nil, defaultGrams: nil,
                    dose: ["manganese": 2.3], doseLabel: "2.3 mg"),
        CatalogItem(key: "folate_mthf", name: "Folate (5-MTHF)",
                    kind: .supplement, detail: "Methylfolate — reject synthetic folic acid.",
                    fdcId: nil, defaultGrams: nil,
                    dose: ["folate": 400], doseLabel: "400 µg DFE"),
    ]
}
