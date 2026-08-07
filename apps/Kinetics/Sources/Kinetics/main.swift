import AppKit
import CoreFoundation
import Darwin
import Foundation
import KineticsCore

@main
struct KineticsEntry {
    static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            KineticsDiagnostics.run()
            return
        }
        if CommandLine.arguments.contains("--switch-left") {
            Darwin.exit(KineticsCLI.runSwitch(KineticsDirectionLeft) ? 0 : 1)
        }
        if CommandLine.arguments.contains("--switch-right") {
            Darwin.exit(KineticsCLI.runSwitch(KineticsDirectionRight) ? 0 : 1)
        }

        let application = NSApplication.shared
        let delegate = KineticsAppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

enum KineticsCLI {
    static func runSwitch(_ direction: KineticsDirection) -> Bool {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: KineticsConstants.DefaultsKey.enabled) as? Bool
            ?? KineticsConstants.defaultEnabled
        guard enabled else {
            print("Kinetics switch refused: engine is disabled")
            return false
        }

        let target = defaults.object(forKey: KineticsConstants.DefaultsKey.targetMilliseconds) as? Double
            ?? KineticsConstants.defaultTargetMilliseconds
        let followReduceMotion = defaults.object(forKey: KineticsConstants.DefaultsKey.followReduceMotion) as? Bool
            ?? KineticsConstants.defaultFollowReduceMotion
        let minimizeSpatialMotion = defaults.object(forKey: KineticsConstants.DefaultsKey.minimizeSpatialMotion) as? Bool
            ?? KineticsConstants.defaultMinimizeSpatialMotion

        kinetics_set_gesture_velocity(CrispMotion.endingVelocity(forTargetMilliseconds: target))
        kinetics_set_snap_mode(minimizeSpatialMotion ||
                               (followReduceMotion && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))

        let accepted = kinetics_switch(direction)
        // Keep the process alive through all phased event delivery. The C
        // engine paces the phases; this pump lets the session event tap and
        // Dock consume them before the CLI exits.
        let deadline = Date().addingTimeInterval(0.25)
        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.025, true)
        }
        print("Kinetics switch \(direction == KineticsDirectionLeft ? "left" : "right"): \(accepted ? "accepted" : "refused")")
        return accepted
    }
}
