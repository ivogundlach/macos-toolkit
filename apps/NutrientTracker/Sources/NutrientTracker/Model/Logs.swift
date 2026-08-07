import Foundation

/// One logged consumption. `nutrients` is the resolved contribution of THIS
/// entry, in canonical units, snapshotted at log time so history stays stable.
struct LoggedItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var date: Date = .now
    var name: String
    var source: Source
    var fdcId: Int?
    var grams: Double?
    var catalogKey: String?
    var nutrients: [String: Double]

    enum Source: String, Codable { case usda, animalFix, supplement, custom }
}

/// GI symptom episode. The goal (per Ivo): learn which foods do what.
struct SymptomEntry: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var date: Date = .now
    var kinds: [String]      // see SymptomKind.all
    var severity: Int        // 1...5
    var note: String = ""
}

enum SymptomKind {
    static let all = ["Bloating", "Cramps", "Diarrhea", "Constipation",
                      "Nausea", "Reflux/Heartburn", "Gas", "Other"]
}

/// User profile, seeded from Nutrition.md. Editable in Settings.
struct Profile: Codable {
    var bodyweightLb: Double = 125
    var framework: String = "Strict animal-based keto (zero fiber)"
    var goal: String = "Caloric surplus for hypertrophy"
    var training: String = "2-hr intense sessions daily"
    var meatKcalLow: Double = 1500
    var meatKcalHigh: Double = 2500
    var meatRatio: String = "Beef : Chicken : Pork = 3 : 1 : 1"
    /// GI correlation: a food eaten within this many hours BEFORE a symptom is
    /// counted as a possible trigger.
    var correlationWindowHours: Double = 12
}
