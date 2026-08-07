import Foundation
import AppKit
import ServiceManagement

/// Start-at-login, registered as the main app rather than as a LaunchAgent.
///
/// `SMAppService.mainApp` hands the launch to LaunchServices, which matters for a
/// menu-bar app: the process is a normal foreground-capable app, so flipping to
/// `.regular` and activating when the user opens the window still works, and macOS
/// refuses to start a second copy of an app that is already running. A LaunchAgent
/// invoking the executable directly gives up both of those.
///
/// It also means the user can turn this off in System Settings → General → Login
/// Items, so that is treated as the source of truth: there is no shadow preference
/// to disagree with it.
enum LoginItem {
    /// Whether a login launch should come up as a menu-bar accessory with no window.
    ///
    /// Determined from the open-application Apple event, which carries a property
    /// saying loginwindow started the process rather than the user opening the app.
    /// Only meaningful while that event is still current, i.e. during
    /// `applicationDidFinishLaunching` — read it once, there.
    ///
    /// Four-char codes spelled out rather than imported from Carbon, matching how
    /// `applicationShouldTerminate` already reads its quit reason:
    /// 'oapp' open-application, 'prdt' property data, 'lgit' launched as login item.
    static func launchedAtLogin() -> Bool {
        let openApplication = AEEventID(0x6F61_7070)
        let propertyData = AEKeyword(0x7072_6474)
        let loginItemLaunch = OSType(0x6C67_6974)

        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == openApplication else { return false }
        return event.paramDescriptor(forKeyword: propertyData)?.enumCodeValue == loginItemLaunch
    }

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Registering an already-registered app throws, as does unregistering one that
    /// was never registered, so both directions check first.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard SMAppService.mainApp.status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status == .enabled else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    /// Vitals is a menu-bar resident, so it defaults to launching with the session.
    /// Applied once and remembered, so that turning it off — here or in System
    /// Settings — is not undone on the next launch.
    static func applyFirstRunDefault() {
        let key = "loginItemConfigured"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        try? setEnabled(true)
        UserDefaults.standard.set(true, forKey: key)
    }
}
