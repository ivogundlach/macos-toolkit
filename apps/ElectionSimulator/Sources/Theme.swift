import SwiftUI

enum Theme {
    // Party colors are reserved for outcomes, margins, and direct party choices.
    static let dem = Color(red: 0.12, green: 0.39, blue: 0.78)
    static let rep = Color(red: 0.79, green: 0.20, blue: 0.23)
    static let ind = Color(red: 0.48, green: 0.34, blue: 0.67)
    static let toss = Color(red: 0.48, green: 0.49, blue: 0.53)
    static let gain = Color(red: 0.12, green: 0.55, blue: 0.37)
    static let loss = Color(red: 0.76, green: 0.43, blue: 0.09)

    // Non-partisan product chrome.
    static let civic = Color(red: 0.12, green: 0.43, blue: 0.52)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let grouped = Color.primary.opacity(0.026)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let panelStrong = Color.primary.opacity(0.048)
    static let border = Color.primary.opacity(0.085)
    static let borderStrong = Color.primary.opacity(0.16)

    // Backwards-compatible alias used by older view helpers.
    static let bg = canvas

    // Liquid Glass. Only top-level cards take it — `panelStrong` and `grouped`
    // stay solid because they are insets *inside* those cards, and glass layered
    // on glass muddies both. Party fills stay flat: they are data, not chrome.
    static let cardGlass: Glass = .regular
    static let interactiveGlass: Glass = .regular.interactive()
    /// Selected chrome keeps a *solid* tint fill rather than tinted glass: the
    /// glass tint goes pale in light appearance and white-on-it fails contrast.

    static func color(_ party: Party) -> Color {
        switch party {
        case .dem: return dem
        case .rep: return rep
        case .ind: return ind
        }
    }

    static func color(_ rating: Rating) -> Color {
        switch rating {
        case .safeD: return dem
        case .likelyD: return dem.opacity(0.82)
        case .leanD: return dem.opacity(0.66)
        case .tossup: return toss
        case .leanR: return rep.opacity(0.66)
        case .likelyR: return rep.opacity(0.82)
        case .safeR: return rep
        }
    }
}
