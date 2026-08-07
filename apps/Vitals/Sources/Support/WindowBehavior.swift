import SwiftUI
import AppKit

/// Hosts the main UI in a hand-managed `NSWindow` instead of a SwiftUI `Window`
/// scene.
///
/// A SwiftUI `Window` scene is the wrong tool for a menu-bar-primary app: closing
/// it terminates the whole process (the AppKit "don't terminate on last window
/// close" delegate is ignored under the SwiftUI lifecycle), and while hidden it
/// re-shows itself every time the app reactivates — e.g. when the menu bar panel
/// opens. A plain NSWindow does neither. Closing it merely hides it; the app lives
/// on in the menu bar until the user picks Quit.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        let hosting = NSHostingController(rootView: RootHostView(model: model))
        window = NSWindow(contentViewController: hosting)
        window.title = "Vitals"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1120, height: 680))
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("VitalsMainWindow")
        window.center()
        super.init()
        window.delegate = self
        MainWindow.controller = self
    }

    /// Bring the window forward and restore the Dock presence.
    func show() {
        model.windowVisible = true
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Hide the window and drop to a menu-bar-only accessory.
    func hide() {
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        model.windowVisible = false   // collapse the content so it stops updating
    }

    /// Hide instead of close. Returning false keeps the window — and therefore the
    /// app — alive.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    /// Also stop updating the table while the window is merely minimised or on a
    /// different Space — same idle-layout cost as being hidden.
    func windowDidMiniaturize(_ notification: Notification) { model.windowVisible = false }
    func windowDidDeminiaturize(_ notification: Notification) { model.windowVisible = true }
}

/// Renders the full UI only while the window is visible; otherwise an inert
/// placeholder, so the process table is not laid out off-screen.
private struct RootHostView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.windowVisible {
                ContentView(model: model)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        // macOS 26 draws a heavy accent focus ring around whatever holds keyboard
        // focus. It reads as an error state here, so the whole window opts out;
        // selection is already shown by the pill fill.
        .focusEffectDisabled()
    }
}

/// Reopen entry point used by the menu bar's "Open Vitals" button.
@MainActor
enum MainWindow {
    weak static var controller: MainWindowController?
    static func show() { controller?.show() }
    static func hide() { controller?.hide() }
}

/// Explicit-quit coordination. The app refuses every termination except one routed
/// through here (menu bar Quit or ⌘Q), so closing the window can never quit it.
@MainActor
enum AppControl {
    weak static var delegate: AppDelegate?
    static func quit() { delegate?.requestQuit() }
}
