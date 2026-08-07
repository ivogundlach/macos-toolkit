import Foundation

enum KineticsConstants {
    static let productName = "Kinetics"
    static let bundleIdentifier = "com.ivogundlach.Kinetics"
    static let loginLauncherIdentifier = "com.ivogundlach.Kinetics.LoginLauncher"
    static let version = "0.1.5"
    static let build = "6"

    static let defaultTargetMilliseconds = 220.0
    static let minimumTargetMilliseconds = 140.0
    static let maximumTargetMilliseconds = 360.0

    static let defaultFollowReduceMotion = true
    static let defaultMinimizeSpatialMotion = false
    static let defaultTrackpadOverride = true
    static let defaultEnabled = true

    enum DockAnimation {
        static let preferencesDomain = "com.apple.dock"
        static let dockBundleIdentifier = "com.apple.dock"
        static let revealDelayKey = "autohide-delay"
        static let revealHideDurationKey = "autohide-time-modifier"
        static let missionControlDurationKey = "expose-animation-duration"

        static let revealDelayRange: ClosedRange<Double> = 0.0...2.0
        static let revealHideDurationRange: ClosedRange<Double> = 0.0...2.0
        static let missionControlDurationRange: ClosedRange<Double> = 0.0...1.0

        static let initialRevealDelay = 0.0
        static let initialRevealHideDuration = 0.5
        static let initialMissionControlDuration = 0.05
    }

    enum DefaultsKey {
        static let enabled = "desktopSwitching.enabled"
        static let targetMilliseconds = "desktopSwitching.targetMilliseconds"
        static let followReduceMotion = "desktopSwitching.followReduceMotion"
        static let minimizeSpatialMotion = "desktopSwitching.minimizeSpatialMotion"
        static let trackpadOverride = "desktopSwitching.trackpadOverride"
    }
}

enum CrispMotion {
    /// The Dock owns the final rendering, so this is a calibrated velocity map,
    /// not a promise of an exact frame duration. 60 is Space Rabbit v2's
    /// documented middle-speed reference; 220 ms is Kinetics' center point.
    static func endingVelocity(forTargetMilliseconds milliseconds: Double) -> Double {
        let clamped = min(max(milliseconds,
                               KineticsConstants.minimumTargetMilliseconds),
                          KineticsConstants.maximumTargetMilliseconds)
        return min(max(60.0 * (KineticsConstants.defaultTargetMilliseconds / clamped), 28.0), 110.0)
    }
}
