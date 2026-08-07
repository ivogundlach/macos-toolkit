import AppKit
import SwiftUI

// @main entry point. Kept in its own file so SwiftPM compiles it as part of the
// library-style executable target (parse-as-library), which the SwiftUI App
// lifecycle requires under Command Line Tools (no Xcode).
@main
struct MarketApp: App {
    @NSApplicationDelegateAdaptor(MarketAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()  // lazy: not built in drain mode

    init() {
        #if IVO_PREVIEW
        let isHeadless = false
        #else
        let isHeadless = CommandLine.arguments.contains("--notify-drain")
            || CommandLine.arguments.contains("--background-refresh")
        #endif
        // Info.plist starts Market as LSUIElement so a launchd refresh never
        // flashes or persists in the Dock. Promote only a real window launch.
        // Foregrounding is NOT done here: Market builds AppModel and loads data
        // before its window exists, so an init-time activate fires too early and
        // never sticks. MarketAppDelegate.applicationDidFinishLaunching and the
        // window's .onAppear own activation, once the window actually exists.
        NSApplication.shared.setActivationPolicy(isHeadless ? .accessory : .regular)

        #if IVO_PREVIEW
        let requestedAppearance = ProcessInfo.processInfo.environment["IVO_PREVIEW_APPEARANCE"]?.lowercased()
        #else
        let requestedAppearance = UserDefaults.standard.string(forKey: "appearance")?.lowercased()
        #endif
        switch requestedAppearance {
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case "system": NSApplication.shared.appearance = nil
        default: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }

        // Headless delivery mode: the launchd pipeline invokes
        // `Market.app/Contents/MacOS/Market --notify-drain` right after enqueueing
        // outbox rows, so push notifications arrive even when the app is CLOSED.
        // Claims + posts + acks + exits before any window or model is created.
        #if !IVO_PREVIEW
        if CommandLine.arguments.contains("--notify-drain") {
            NotifyDrain.runAndExit()
        }
        if CommandLine.arguments.contains("--background-refresh") {
            BackgroundRefresh.runAndExit()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup("Market") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 480)
                // macOS 26 draws a heavy accent focus ring around whatever holds
                // keyboard focus. It reads as an error state here, so the whole
                // window opts out; selection is already shown by the row fill.
                .focusEffectDisabled()
                .onAppear {
                    // Belt-and-suspenders: by the time the window content
                    // appears the NSWindow exists, so this activate reliably
                    // sticks even if applicationDidFinishLaunching ran before it.
                    MarketAppDelegate.bringToFront()
                }
        }
        .defaultSize(width: 1120, height: 760)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {} // single-window hub
        }
    }
}

/// Owns window foregrounding for real (non-headless) launches. Market ships as
/// LSUIElement and promotes to .regular in MarketApp.init; Launch Services does
/// not activate an app that flips policy that way, so without this the window
/// opens behind the frontmost app until the Dock icon is clicked.
final class MarketAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.bringToFront()
    }

    // NOTE: do NOT flip the activation policy to .accessory on the way out to
    // clear the ghost Dock tile. Becoming an accessory app orders every window
    // out, so SwiftUI persists "no open windows" and WindowGroup restores ZERO
    // windows on the next launch — and Market removes ⌘N (single-window hub), so
    // there is no way to get the window back. Verified 2026-07-20: with that
    // code the app launched visible, .regular, menu bar present, 0 windows.

    /// Activate + key the window, but only for a real windowed launch. In
    /// headless drain/refresh mode the process stays .accessory (and usually
    /// exits inside MarketApp.init before this runs), so this is a no-op there.
    static func bringToFront() {
        guard NSApp.activationPolicy() == .regular else { return }
        NSApp.activate(ignoringOtherApps: true)
        // The NSWindow may land in the window list a run-loop turn after the
        // activate/appear signal; re-assert on the next turn so it is key.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            (NSApp.windows.first { $0.canBecomeKey } ?? NSApp.windows.first)?
                .makeKeyAndOrderFront(nil)
        }
    }
}

#if !IVO_PREVIEW
private enum BackgroundRefresh {
    static func runAndExit() -> Never {
        // A deep X pass can exceed one scheduler interval. Because this executable
        // is also an AppKit app, macOS may otherwise classify the windowless process
        // as idle and terminate it while its child is still scraping. Keep the signed
        // app identity alive until the dispatcher returns; the dispatcher owns its
        // own lock and adapter timeout.
        ProcessInfo.processInfo.disableAutomaticTermination("Market background refresh is running")
        ProcessInfo.processInfo.disableSuddenTermination()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Users/YOUR_USERNAME/.local/bin/market-refresh")
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            exit(process.terminationStatus)
        } catch {
            FileHandle.standardError.write(Data("Market background refresh failed to start: \(error)\n".utf8))
            exit(127)
        }
    }
}
#endif
