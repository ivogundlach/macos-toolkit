import AppKit
import SwiftUI

#if IVO_PREVIEW
private struct PreviewWindowSizer: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.setContentSize(NSSize(width: width, height: height))
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif

@main
struct MacroSimulatorApp: App {
    private var previewWidth: CGFloat {
        #if IVO_PREVIEW
        if let value = ProcessInfo.processInfo.environment["IVO_PREVIEW_WIDTH"],
           let width = Double(value) { return width }
        #endif
        return 1460
    }

    private var previewHeight: CGFloat {
        #if IVO_PREVIEW
        if let value = ProcessInfo.processInfo.environment["IVO_PREVIEW_HEIGHT"],
           let height = Double(value) { return height }
        #endif
        return 860
    }

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
        Window("Tax Simulator", id: "main") {
            DashboardView()
                // macOS 26 draws a heavy accent focus ring around whatever holds
                // keyboard focus. It reads as an error state here, so the whole
                // window opts out; selection is already shown by the control fill.
                .focusEffectDisabled()
                #if IVO_PREVIEW
                .background(PreviewWindowSizer(width: previewWidth, height: previewHeight))
                #endif
        }
        .windowStyle(.titleBar)
        .defaultSize(width: previewWidth, height: previewHeight)
        .windowResizability(.contentMinSize)
    }
}
