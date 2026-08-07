import AppKit
import Foundation

struct KineticsShortcut: Equatable {
    enum Source: Equatable {
        case detected(id: Int, rawFlags: UInt64)
        case fallback

        var isFallback: Bool {
            if case .fallback = self { return true }
            return false
        }
    }

    let keyCode: Int64
    let modifierMask: UInt64
    let source: Source

    var displayLabel: String {
        let modifiers: [(UInt64, String)] = [
            (ShortcutResolver.commandMask, "Command"),
            (ShortcutResolver.optionMask, "Option"),
            (ShortcutResolver.controlMask, "Control"),
            (ShortcutResolver.shiftMask, "Shift")
        ]
        let prefix = modifiers
            .filter { displayModifierMask & $0.0 != 0 }
            .map(\.1)
            .joined(separator: "-")
        let key = ShortcutResolver.keyLabel(for: keyCode)
        return prefix.isEmpty ? key : "\(prefix)-\(key)"
    }

    private var displayModifierMask: UInt64 {
        modifierMask
    }

    var sourceLabel: String {
        switch source {
        case .detected(let id, _): return "Detected symbolic hotkey \(id)"
        case .fallback: return "Fallback Control-arrow binding"
        }
    }
}

struct KineticsShortcutResolution: Equatable {
    let left: KineticsShortcut
    let right: KineticsShortcut

    var usesFallback: Bool { left.source.isFallback || right.source.isFallback }
    var statusLabel: String {
        usesFallback ? "Fallback active for one or more shortcuts" : "Resolved from AppleSymbolicHotKeys"
    }
}

enum ShortcutResolver {
    // These are the CGEvent/NSEvent modifier values shared by the symbolic
    // hotkey parameters and CGEventFlags. Fn, numeric-pad, and noncoalesced
    // bits are deliberately outside this mask and therefore ignored.
    static let commandMask: UInt64 = 1 << 20
    static let optionMask: UInt64 = 1 << 19
    static let controlMask: UInt64 = 1 << 18
    static let shiftMask: UInt64 = 1 << 17
    static let relevantMask = commandMask | optionMask | controlMask | shiftMask
    static let standardSpaceSwitchRawFlags: UInt64 = 8_781_824

    static let fallbackLeft = KineticsShortcut(keyCode: 123,
                                                modifierMask: controlMask,
                                                source: .fallback)
    static let fallbackRight = KineticsShortcut(keyCode: 124,
                                                 modifierMask: controlMask,
                                                 source: .fallback)
    static let fallback = KineticsShortcutResolution(left: fallbackLeft, right: fallbackRight)

    private static let leftIDs = [79, 80]
    private static let rightIDs = [81, 82]

    static func resolve() -> KineticsShortcutResolution {
        guard let hotkeys = symbolicHotkeys() else { return fallback }
        let left = firstEnabledShortcut(in: hotkeys, ids: leftIDs) ?? fallbackLeft
        let right = firstEnabledShortcut(in: hotkeys, ids: rightIDs) ?? fallbackRight
        return KineticsShortcutResolution(left: left, right: right)
    }

    static func keyLabel(for keyCode: Int64) -> String {
        switch keyCode {
        case 123: return "Left Arrow"
        case 124: return "Right Arrow"
        case 125: return "Down Arrow"
        case 126: return "Up Arrow"
        default: return "Keycode \(keyCode)"
        }
    }

    private static func isStandardSpaceSwitch(id: Int,
                                              keyCode: Int64,
                                              rawFlags: UInt64) -> Bool {
        rawFlags == standardSpaceSwitchRawFlags &&
            ((id == 80 && keyCode == 123) || (id == 82 && keyCode == 124))
    }

    private static func symbolicHotkeys() -> NSDictionary? {
        if let object = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .object(forKey: "AppleSymbolicHotKeys") as? NSDictionary {
            return object
        }

        // CFPreferences is a useful fallback when the suite is not materialized
        // in Foundation's search list yet (for example immediately after login).
        let object = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
                                                "com.apple.symbolichotkeys" as CFString)
        return object as? NSDictionary
    }

    private static func firstEnabledShortcut(in hotkeys: NSDictionary,
                                             ids: [Int]) -> KineticsShortcut? {
        for id in ids {
            let entry = hotkeys.object(forKey: String(id)) as? NSDictionary
                ?? hotkeys.object(forKey: NSNumber(value: id)) as? NSDictionary
            guard let entry,
                  (entry.object(forKey: "enabled") as? NSNumber)?.boolValue == true,
                  let value = entry.object(forKey: "value") as? NSDictionary,
                  let parameters = value.object(forKey: "parameters") as? [Any],
                  parameters.count >= 3,
                  let keyCode = (parameters[1] as? NSNumber)?.int64Value,
                  let rawFlags = (parameters[2] as? NSNumber)?.uint64Value,
                  keyCode >= 0 else {
                continue
            }

            // macOS stores extra private bits (including Shift) for the
            // standard desktop-switch entries, but the physical shortcut is
            // Control-Left/Right Arrow. Keep custom symbolic shortcuts
            // literal while normalizing only the exact standard entries.
            let modifierMask = isStandardSpaceSwitch(id: id,
                                                      keyCode: keyCode,
                                                      rawFlags: rawFlags)
                ? controlMask
                : rawFlags & relevantMask
            return KineticsShortcut(keyCode: keyCode,
                                    modifierMask: modifierMask,
                                    source: .detected(id: id, rawFlags: rawFlags))
        }
        return nil
    }
}
