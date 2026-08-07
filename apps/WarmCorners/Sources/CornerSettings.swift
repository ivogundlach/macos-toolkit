import AppKit
import Observation
import ServiceManagement

/// Single source of truth for the corner map and the app-wide toggles.
/// Persisted as one JSON blob so adding a field never needs a defaults migration.
@Observable
final class CornerSettings {
    private static let storeKey = "warmcorners.config"

    private struct Store: Codable {
        var actions: [String: CornerAction] = [:]
        var showIndicator = true
        var isPaused = false
    }

    private var store: Store {
        didSet { save() }
    }

    init() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let decoded = try? JSONDecoder().decode(Store.self, from: data) {
            store = decoded
        } else {
            store = Store(actions: Self.importedFromHotCorners())
            save()
        }
    }

    var hasAnyCornerSet: Bool {
        Corner.allCases.contains { action(for: $0).isActive }
    }

    func action(for corner: Corner) -> CornerAction {
        store.actions[corner.rawValue] ?? CornerAction(appPath: nil)
    }

    func setAction(_ action: CornerAction, for corner: Corner) {
        store.actions[corner.rawValue] = action
    }

    var showIndicator: Bool {
        get { store.showIndicator }
        set { store.showIndicator = newValue }
    }

    var isPaused: Bool {
        get { store.isPaused }
        set { store.isPaused = newValue }
    }

    /// Mirrors the login-items database, which is the real store; kept as a stored
    /// property so SwiftUI sees the change.
    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("WarmCorners: launch at login failed: %@", String(describing: error))
                launchAtLogin = oldValue
            }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        UserDefaults.standard.set(data, forKey: Self.storeKey)
    }

    /// First run only: adopt whatever the Hot Corners app was already set to, so the
    /// corners keep working without being reconfigured by hand.
    private static func importedFromHotCorners() -> [String: CornerAction] {
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/com.hotcorners.app.prod/Data/Library/Preferences/com.hotcorners.app.prod.plist")
        guard let existing = NSDictionary(contentsOf: plist) else { return [:] }

        let keys: [Corner: String] = [
            .topLeft: "hot_corners_top_left_url",
            .topRight: "hot_corners_top_right_url",
            .bottomLeft: "hot_corners_bottom_left_url",
            .bottomRight: "hot_corners_bottom_right_url",
        ]
        var actions: [String: CornerAction] = [:]
        for (corner, key) in keys {
            guard let path = existing[key] as? String,
                  FileManager.default.fileExists(atPath: path) else { continue }
            actions[corner.rawValue] = CornerAction(appPath: path, delay: 0.5)
        }
        return actions
    }
}
