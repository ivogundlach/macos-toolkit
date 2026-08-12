import SwiftUI

@main
struct SchoolDashboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("School", id: "main") {
            ContentView(model: delegate.model)
                // macOS 26 draws a focus ring on almost everything; kill it at
                // the root rather than per control.
                .focusEffectDisabled()
                .frame(minWidth: 940, minHeight: 620)
        }
        .defaultSize(width: 1080, height: 740)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") { delegate.model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = SchoolModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A regular Dock app whose window can otherwise open behind whatever
        // Ivo was already looking at.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
