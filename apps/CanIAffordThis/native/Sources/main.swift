import SwiftUI

@main
struct RunwayApp: App {
    var body: some Scene {
        WindowGroup {
            DashboardView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
