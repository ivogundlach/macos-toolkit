import Foundation
import KineticsCore

enum KineticsDiagnostics {
    static func run() {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        let augmentation = kinetics_requires_event_augmentation() ? "active" : "inactive"
        let trusted = kinetics_is_accessibility_trusted() ? "trusted" : "not trusted"
        let shortcuts = ShortcutResolver.resolve()
        let defaults = UserDefaults.standard
        let target = defaults.object(forKey: KineticsConstants.DefaultsKey.targetMilliseconds) as? Double
            ?? KineticsConstants.defaultTargetMilliseconds
        let trackpadOverride = defaults.object(forKey: KineticsConstants.DefaultsKey.trackpadOverride) as? Bool
            ?? KineticsConstants.defaultTrackpadOverride
        var info = KineticsSpaceInfo()
        let space: String
        if kinetics_get_space_info(&info) {
            space = "index=\(info.currentIndex + 1) count=\(info.spaceCount)"
        } else {
            space = "unavailable (CoreGraphics Services did not expose current spaces)"
        }

        print("Kinetics version: \(KineticsConstants.version)")
        print("Kinetics build: \(KineticsConstants.build)")
        print("OS version: \(os)")
        print("macOS 27 event augmentation: \(augmentation)")
        print("Current space: \(space)")
        print("Accessibility: \(trusted)")
        print(String(format: "Crisp target: %.0f ms (calibrated target)", target))
        print("Trackpad override: \(trackpadOverride ? "enabled" : "disabled")")
        print("Shortcut resolution: \(shortcuts.statusLabel)")
        print("Desktop switch left: \(shortcuts.left.displayLabel) [\(shortcuts.left.sourceLabel)]")
        print("Desktop switch right: \(shortcuts.right.displayLabel) [\(shortcuts.right.sourceLabel)]")

        print("Dock animation diagnostics: read-only")
        switch DockAnimationPreferences.readLiveValues() {
        case .success(let values):
            print(String(format: "Dock reveal delay: %g s", values.revealDelay))
            print(String(format: "Dock reveal/hide duration: %g s", values.revealHideDuration))
            print(String(format: "Mission Control duration: %g s", values.missionControlDuration))
        case .failure(let error):
            print("Dock animation values: unavailable (\(error.localizedDescription))")
        }
    }
}
