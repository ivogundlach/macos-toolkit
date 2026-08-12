import AppKit
import SwiftUI

// Offscreen design harness. Renders each tab to a PNG with ImageRenderer so the
// layout can be reviewed without opening a window — no focus stolen, no Dock
// icon, safe to run while Ivo is working.
//
// Caveat worth knowing when reading the output: ImageRenderer has no backdrop,
// so `refractiveGlass` surfaces render flat here. Layout, type, spacing, and
// colour are faithful; the glass material is not.
//
//   ./scripts/render-preview.sh [light|dark]

@main
struct RenderPreview {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        let appearanceName: String = args.count > 1 ? args[1] : "dark"
        let outputDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "build/preview")
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: appearanceName == "light" ? .aqua : .darkAqua)

        guard let snapshot = loadSnapshot() else {
            FileHandle.standardError.write(Data("no snapshot to render\n".utf8))
            exit(1)
        }

        let size = CGSize(width: 1180, height: 820)
        for tab in Tab.allCases {
            let view = PreviewShell(snapshot: snapshot, tab: tab)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, appearanceName == "light" ? .light : .dark)
            guard let png = render(view, size: size) else {
                FileHandle.standardError.write(Data("render failed: \(tab.rawValue)\n".utf8))
                continue
            }
            let name = "\(appearanceName)-\(tab.rawValue.lowercased()).png"
            try? png.write(to: outputDir.appendingPathComponent(name))
            print("wrote \(outputDir.appendingPathComponent(name).path)")
        }
        exit(0)
    }

    /// Renders through a real (never-shown) window rather than `ImageRenderer`.
    /// `ImageRenderer` gives a `ScrollView` no layout pass, so every scrolling
    /// tab came out as an empty rectangle. An offscreen `NSWindow` gets a real
    /// AppKit layout; it is never ordered front, so focus never moves.
    @MainActor
    static func render(_ view: some View, size: CGSize) -> Data? {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // One turn of the runloop so SwiftUI commits its first layout pass.
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    static func loadSnapshot() -> Snapshot? {
        guard let data = try? Data(contentsOf: SchoolModel.snapshotURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}

/// Mirrors ContentView without the live model, so the harness stays a pure
/// function of the snapshot on disk.
struct PreviewShell: View {
    let snapshot: Snapshot
    let tab: Tab
    @StateObject private var model = SchoolModel()

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model, tab: .constant(tab))
            Divider()
            Group {
                switch tab {
                case .overview:
                    OverviewView(model: model, snapshot: snapshot, tab: .constant(tab))
                case .assignments:
                    AssignmentsView(snapshot: snapshot)
                case .schedule:
                    ScheduleView(snapshot: snapshot)
                case .courses:
                    CoursesView(snapshot: snapshot)
                case .grades:
                    GradesView(model: model, snapshot: snapshot)
                case .status:
                    StatusView(model: model, snapshot: snapshot)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SchoolTheme.page)
    }
}
