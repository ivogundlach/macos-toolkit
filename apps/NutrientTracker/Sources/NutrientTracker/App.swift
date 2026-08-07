import SwiftUI
import AppKit

#if IVO_PREVIEW
private struct PreviewWindowSizer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let window = view.window else { return }
            let width = Double(ProcessInfo.processInfo.environment["IVO_PREVIEW_WIDTH"] ?? "1120") ?? 1120
            let height = Double(ProcessInfo.processInfo.environment["IVO_PREVIEW_HEIGHT"] ?? "760") ?? 760
            window.setContentSize(NSSize(width: width - 1, height: height))
            window.setContentSize(NSSize(width: width, height: height))
            window.displayIfNeeded()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif

/// Section order reflects the app's philosophy: this is a medium/long-term
/// health tracker. Habitual status leads; daily views exist only for data
/// entry (Log) and drill-down (Day detail).
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case longterm = "Long-term Health"
    case trends = "Trends"
    case gi = "GI Tracking"
    case today = "Log"
    case gaps = "Day Detail"
    case settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .longterm: return "calendar.badge.clock"
        case .trends: return "chart.xyaxis.line"
        case .gi: return "waveform.path.ecg"
        case .today: return "square.and.pencil"
        case .gaps: return "chart.bar.doc.horizontal"
        case .settings: return "gearshape"
        }
    }
}

/// Cross-view UI state (navigation + the day being viewed). Per-view transient
/// state lives in each view's own @StateObject view-model.
final class AppState: ObservableObject {
    @Published var section: AppSection? = .longterm
    @Published var selectedDay: Date = .now

    init() {
        #if IVO_PREVIEW
        if let requested = ProcessInfo.processInfo.environment["IVO_PREVIEW_SECTION"],
           let match = AppSection.allCases.first(where: {
               $0.rawValue.caseInsensitiveCompare(requested) == .orderedSame
           }) {
            section = match
        }
        #endif
    }
}

@main
struct NutrientTrackerApp: App {
    @StateObject private var store = Store()
    @StateObject private var app = AppState()

    init() {
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
        // Guarantee the window opens frontmost; ad-hoc-signed launches can
        // otherwise land behind the previously active app.
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(app)
                .frame(minWidth: 940, minHeight: 640)
                // The one app in the fleet that carried the glass without ever
                // installing the light behind it: its panes read the environment's
                // default field, so every rim sat at a fixed bearing and nothing
                // here responded to the pointer at all.
                .refractiveCanvas()
                // macOS 26 draws a heavy accent focus ring around whatever holds
                // keyboard focus. It reads as an error state here, so the whole
                // window opts out; selection is already shown by the row fill.
                .focusEffectDisabled()
                #if IVO_PREVIEW
                .background(PreviewWindowSizer())
                #endif
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1120, height: 760)
        .windowToolbarStyle(.unifiedCompact)
    }
}
