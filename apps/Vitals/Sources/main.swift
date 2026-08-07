import SwiftUI
import AppKit

/// Entry point. The same binary serves the UI and the headless recorder, so the
/// LaunchAgent has nothing extra to install and can never drift out of sync with
/// the app's sampling code.
///
/// Arguments: `--daemon` runs the headless recorder, `--menu-bar` starts the UI in
/// the menu bar with no window (the same state a login launch produces).
if CommandLine.arguments.contains("--daemon") {
    BackgroundSampler.runDaemon()      // never returns
}

VitalsApp.main()

/// The app owns only the menu bar and Settings as SwiftUI scenes. The main window
/// is a hand-managed NSWindow (see MainWindowController) so that closing it keeps
/// the app alive in the menu bar instead of terminating it.
struct VitalsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(model: delegate.model)
                .focusEffectDisabled()
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: delegate.model)
                .focusEffectDisabled()
        }
        // Route ⌘Q through the explicit-quit path; the default Quit command would be
        // swallowed by the termination gate below and appear to do nothing.
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Vitals") { AppControl.quit() }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owned here (not as an @StateObject) so the manual main window, the menu bar
    /// and Settings all share one sampling model.
    let model = AppModel()
    private var mainWindowController: MainWindowController?
    private var userRequestedQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppControl.delegate = self
        // Read before anything else: this is only valid while the open-application
        // Apple event is still the current one. `--menu-bar` forces the same path,
        // which is what makes it testable without logging out.
        let menuBarOnly = LoginItem.launchedAtLogin()
            || CommandLine.arguments.contains("--menu-bar")
        LoginItem.applyFirstRunDefault()

        // Set before the controller is built, so a login launch never lays the
        // process table out for a window that is not going to appear.
        model.windowVisible = !menuBarOnly
        let controller = MainWindowController(model: model)
        mainWindowController = controller

        if menuBarOnly {
            // Menu bar only: no window, no Dock icon. The menu bar item is a scene,
            // so it appears regardless of activation policy.
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
            controller.show()
        }
    }

    /// The only sanctioned way to quit: the menu bar Quit button or ⌘Q.
    func requestQuit() {
        userRequestedQuit = true
        NSApp.terminate(nil)
    }

    /// The definitive termination gate. Whatever tries to end the process —
    /// closing the window, a "last window closed" event, a stray `terminate:` from
    /// SwiftUI — is refused and turned into "hide to the menu bar", unless the user
    /// explicitly asked to quit. This is what guarantees the menu bar item survives
    /// a window close.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if userRequestedQuit { return .terminateNow }
        // A genuine logout / restart / shutdown carries a quit-reason attribute
        // ('why?'); let those through so Vitals never blocks the user from ending
        // their session. A window close has no Apple event at all, so it is refused.
        let quitReason = AEKeyword(0x7768_793F)
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.attributeDescriptor(forKeyword: quitReason) != nil {
            return .terminateNow
        }
        mainWindowController?.hide()
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
