import AppKit
import Foundation
import KineticsCore
import os
import ServiceManagement

enum KineticsEngineState: Equatable {
    case disabled
    case needsAccessibility
    case inactive(String)
    case ready

    var label: String {
        switch self {
        case .disabled: return "Kinetics is off"
        case .needsAccessibility: return "Accessibility access needed"
        case .inactive(let reason): return reason
        case .ready: return "Ready"
        }
    }

    var isReady: Bool { self == .ready }
}

@MainActor
final class KineticsModel: ObservableObject {
    let logger = Logger(subsystem: KineticsConstants.bundleIdentifier, category: "state")
    private let defaults: UserDefaults
    private var refreshTimer: Timer?

    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: KineticsConstants.DefaultsKey.enabled)
            configureEngine()
        }
    }
    @Published var targetMilliseconds: Double {
        didSet {
            let clamped = min(max(targetMilliseconds,
                                  KineticsConstants.minimumTargetMilliseconds),
                              KineticsConstants.maximumTargetMilliseconds)
            if targetMilliseconds != clamped {
                targetMilliseconds = clamped
                return
            }
            defaults.set(targetMilliseconds, forKey: KineticsConstants.DefaultsKey.targetMilliseconds)
            kinetics_set_gesture_velocity(CrispMotion.endingVelocity(forTargetMilliseconds: targetMilliseconds))
        }
    }
    @Published var followReduceMotion: Bool {
        didSet { defaults.set(followReduceMotion, forKey: KineticsConstants.DefaultsKey.followReduceMotion) }
    }
    @Published var minimizeSpatialMotion: Bool {
        didSet { defaults.set(minimizeSpatialMotion, forKey: KineticsConstants.DefaultsKey.minimizeSpatialMotion) }
    }
    @Published var trackpadOverride: Bool {
        didSet {
            defaults.set(trackpadOverride, forKey: KineticsConstants.DefaultsKey.trackpadOverride)
            kinetics_set_trackpad_override(trackpadOverride)
        }
    }

    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var eventTapActive = false
    @Published private(set) var spaceIndex: Int?
    @Published private(set) var spaceCount: Int?
    @Published private(set) var state: KineticsEngineState = .disabled
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var shortcutResolution = ShortcutResolver.fallback

    // The standard domain is stored under this bundle's identifier by LaunchServices;
    // using a suite with the same identifier is rejected by newer Foundation builds.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.enabled = defaults.object(forKey: KineticsConstants.DefaultsKey.enabled) as? Bool
            ?? KineticsConstants.defaultEnabled
        self.targetMilliseconds = defaults.object(forKey: KineticsConstants.DefaultsKey.targetMilliseconds) as? Double
            ?? KineticsConstants.defaultTargetMilliseconds
        self.followReduceMotion = defaults.object(forKey: KineticsConstants.DefaultsKey.followReduceMotion) as? Bool
            ?? KineticsConstants.defaultFollowReduceMotion
        self.minimizeSpatialMotion = defaults.object(forKey: KineticsConstants.DefaultsKey.minimizeSpatialMotion) as? Bool
            ?? KineticsConstants.defaultMinimizeSpatialMotion
        self.trackpadOverride = defaults.object(forKey: KineticsConstants.DefaultsKey.trackpadOverride) as? Bool
            ?? KineticsConstants.defaultTrackpadOverride

        if defaults.object(forKey: KineticsConstants.DefaultsKey.enabled) == nil {
            defaults.set(enabled, forKey: KineticsConstants.DefaultsKey.enabled)
        }
        if defaults.object(forKey: KineticsConstants.DefaultsKey.targetMilliseconds) == nil {
            defaults.set(targetMilliseconds, forKey: KineticsConstants.DefaultsKey.targetMilliseconds)
        }
        if defaults.object(forKey: KineticsConstants.DefaultsKey.followReduceMotion) == nil {
            defaults.set(followReduceMotion, forKey: KineticsConstants.DefaultsKey.followReduceMotion)
        }
        if defaults.object(forKey: KineticsConstants.DefaultsKey.minimizeSpatialMotion) == nil {
            defaults.set(minimizeSpatialMotion, forKey: KineticsConstants.DefaultsKey.minimizeSpatialMotion)
        }
        if defaults.object(forKey: KineticsConstants.DefaultsKey.trackpadOverride) == nil {
            defaults.set(trackpadOverride, forKey: KineticsConstants.DefaultsKey.trackpadOverride)
        }

        kinetics_set_trackpad_override(trackpadOverride)
        kinetics_set_gesture_velocity(CrispMotion.endingVelocity(forTargetMilliseconds: targetMilliseconds))
        launchAtLogin = SMAppService.loginItem(identifier: KineticsConstants.loginLauncherIdentifier).status == .enabled
        applyShortcutResolution(ShortcutResolver.resolve())
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    var targetLabel: String { "\(Int(targetMilliseconds.rounded())) ms" }

    var velocityLabel: String {
        String(format: "%.0f", CrispMotion.endingVelocity(forTargetMilliseconds: targetMilliseconds))
    }

    var spaceLabel: String {
        guard let index = spaceIndex, let count = spaceCount else { return "Space status unavailable" }
        return "Desktop \(index + 1) of \(count)"
    }

    var canTest: Bool { enabled && state.isReady }

    func refresh() {
        accessibilityTrusted = kinetics_is_accessibility_trusted()
        eventTapActive = kinetics_is_event_tap_active()
        launchAtLogin = SMAppService.loginItem(identifier: KineticsConstants.loginLauncherIdentifier).status == .enabled
        applyShortcutResolution(ShortcutResolver.resolve())
        kinetics_set_snap_mode(minimizeSpatialMotion ||
                               (followReduceMotion && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))

        if enabled {
            configureEngine()
        } else {
            state = .disabled
        }

        var info = KineticsSpaceInfo()
        if kinetics_get_space_info(&info) {
            spaceIndex = Int(info.currentIndex)
            spaceCount = Int(info.spaceCount)
        } else {
            spaceIndex = nil
            spaceCount = nil
        }
    }

    func configureEngine() {
        if !enabled {
            kinetics_set_enabled(false)
            state = .disabled
            logger.info("Kinetics disabled")
            return
        }

        guard accessibilityTrusted else {
            kinetics_set_enabled(false)
            state = .needsAccessibility
            return
        }

        if !eventTapActive {
            eventTapActive = kinetics_start_event_tap()
        }
        guard eventTapActive else {
            kinetics_set_enabled(false)
            state = .inactive("Event tap could not be installed")
            logger.error("Accessibility is trusted but event tap creation failed")
            return
        }

        kinetics_set_enabled(true)
        state = .ready
        logger.info("Kinetics engine ready")
    }

    private func applyShortcutResolution(_ resolution: KineticsShortcutResolution) {
        shortcutResolution = resolution
        kinetics_set_shortcuts(resolution.left.keyCode,
                               resolution.left.modifierMask,
                               resolution.right.keyCode,
                               resolution.right.modifierMask)
    }

    func setMinimizeMode(forSystemReduceMotion reduceMotion: Bool) {
        kinetics_set_snap_mode(minimizeSpatialMotion || (followReduceMotion && reduceMotion))
    }

    func test(_ direction: KineticsDirection, reduceMotion: Bool) {
        guard canTest else { return }
        setMinimizeMode(forSystemReduceMotion: reduceMotion)
        let accepted = kinetics_switch(direction)
        let label = direction == KineticsDirectionLeft ? "left" : "right"
        logger.info("Test switch \(label, privacy: .public), accepted=\(accepted, privacy: .public)")
        if accepted { refresh() }
    }

    func requestAccessibility() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let loginItem = SMAppService.loginItem(identifier: KineticsConstants.loginLauncherIdentifier)
        do {
            if enabled {
                if loginItem.status != .enabled { try loginItem.register() }
            } else if loginItem.status == .enabled {
                try loginItem.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            logger.error("Launch at login change failed: \(error.localizedDescription, privacy: .public)")
        }
        launchAtLogin = loginItem.status == .enabled
    }
}
