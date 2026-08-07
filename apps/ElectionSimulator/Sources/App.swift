import SwiftUI
import AppKit

#if IVO_PREVIEW
private struct PreviewWindowRedraw: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let window = view.window else { return }
            let original = window.frame
            var nudged = original
            nudged.size.width += 1
            window.setFrame(nudged, display: true)
            window.setFrame(original, display: true)
            window.contentView?.needsDisplay = true
            window.displayIfNeeded()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif

@main
struct PsephosApp: App {
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
        WindowGroup("Psephos — Election Simulator") {
            ContentView()
                // macOS 26 draws a heavy accent focus ring around whatever holds
                // keyboard focus. It reads as an error state here, so the whole
                // window opts out; selection is already shown by the pill fill.
                .focusEffectDisabled()
                #if IVO_PREVIEW
                .background(PreviewWindowRedraw())
                #endif
        }
        .defaultSize(width: 1180, height: 820)
    }
}
