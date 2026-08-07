import AppKit
import SwiftUI

/// Menu-bar only app: the status item owns the menu, Settings is a hand-managed
/// window so closing it leaves the corners running.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = CornerSettings()
    private lazy var indicator = IndicatorWindow()
    private lazy var watcher = CornerWatcher(settings: settings, indicator: indicator)

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var pauseItem: NSMenuItem?
    private var loginItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        makeStatusItem()
        watcher.start()
        if !settings.hasAnyCornerSet {
            showSettings()
        }
    }

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let symbols = ["rectangle.inset.topleft.filled", "square.topthird.inset.filled", "square.dashed"]
        item.button?.image = symbols.lazy
            .compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: "Warm Corners") }
            .first
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        pauseItem = menu.addItem(withTitle: "Pause", action: #selector(togglePause), keyEquivalent: "")
        pauseItem?.target = self
        menu.addItem(.separator())
        loginItem = menu.addItem(withTitle: "Start at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem?.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Warm Corners", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    /// Opening the app again (Finder, Spotlight, `open -a`) is the only obvious
    /// gesture a menu-bar app has left, so treat it as "show me the settings".
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        pauseItem?.state = settings.isPaused ? .on : .off
        loginItem?.state = settings.launchAtLogin ? .on : .off
    }

    @objc private func togglePause() {
        settings.isPaused.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        settings.launchAtLogin.toggle()
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settings) { [weak self] corner in
                self?.watcher.demo(corner: corner)
            }
            // macOS 26 draws a heavy accent focus ring around whatever holds
            // keyboard focus. It reads as an error state here, so the whole
            // window opts out; the armed corner is already shown by its glyph.
            let window = NSWindow(
                contentViewController: NSHostingController(rootView: view.focusEffectDisabled())
            )
            window.title = "Warm Corners"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        // An accessory app has to ask for activation or the window opens behind.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

// Top-level code already runs on the main thread; state it for the compiler.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
