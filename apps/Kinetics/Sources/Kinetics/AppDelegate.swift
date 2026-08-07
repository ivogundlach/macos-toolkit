import AppKit
import SwiftUI

@MainActor
final class KineticsAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = KineticsModel()
    private var settingsWindow: NSWindow?
    private var userRequestedQuit = false
    private let loginLaunch = CommandLine.arguments.contains("--login")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.refresh()
        guard !loginLaunch else { return }
        // Let AppKit finish installing the delegate before creating the one
        // settings window used by ordinary/manual launches.
        DispatchQueue.main.async { [weak self] in self?.openSettings() }
    }

    func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingView(
                rootView: KineticsSettingsView(model: model, quit: quit)
                    .focusEffectDisabled()
            )
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered,
                                  defer: false)
            window.title = "Kinetics"
            window.titleVisibility = .visible
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = hosting
            window.minSize = NSSize(width: 680, height: 480)
            window.center()
            settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func quit() {
        userRequestedQuit = true
        NSApp.terminate(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        userRequestedQuit ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
