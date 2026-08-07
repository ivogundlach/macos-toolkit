import AppKit
import Observation
import SwiftUI

@Observable
@MainActor
final class IndicatorModel {
    var progress: Double = 0
    var icon: NSImage?
}

/// The countdown that makes the delay visible: a small ring in the corner that
/// fills while the pointer rests there. Click-through, floats over full-screen
/// apps, and never takes focus.
@MainActor
final class IndicatorWindow {
    private let model = IndicatorModel()
    private let panel: NSPanel
    private let size: CGFloat = 54
    private let inset: CGFloat = 10

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: IndicatorView(model: model))
    }

    func show(corner: Corner, screen: NSScreen, appURL: URL?) {
        model.progress = 0
        model.icon = appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
        panel.setFrame(frame(for: corner, on: screen), display: false)
        panel.orderFrontRegardless()
    }

    func update(progress: Double) {
        model.progress = min(max(progress, 0), 1)
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func frame(for corner: Corner, on screen: NSScreen) -> NSRect {
        let f = screen.frame
        let origin: CGPoint
        switch corner {
        case .topLeft: origin = CGPoint(x: f.minX + inset, y: f.maxY - inset - size)
        case .topRight: origin = CGPoint(x: f.maxX - inset - size, y: f.maxY - inset - size)
        case .bottomLeft: origin = CGPoint(x: f.minX + inset, y: f.minY + inset)
        case .bottomRight: origin = CGPoint(x: f.maxX - inset - size, y: f.minY + inset)
        }
        return NSRect(origin: origin, size: CGSize(width: size, height: size))
    }
}

private struct IndicatorView: View {
    @Bindable var model: IndicatorModel

    var body: some View {
        ZStack {
            // Floats over arbitrary desktop content, so it lenses what is behind it
            // rather than flat-blurring it.
            Circle()
                .fill(.clear)
                .glassEffect(WarmUI.indicatorGlass, in: .circle)

            Circle()
                .trim(from: WarmUI.indicatorSpecularStart, to: WarmUI.indicatorSpecularEnd)
                .stroke(
                    WarmUI.indicatorSpecular,
                    style: StrokeStyle(
                        lineWidth: WarmUI.indicatorSpecularWidth,
                        lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(WarmUI.indicatorSpecularPadding)

            Circle()
                .trim(from: WarmUI.indicatorCausticStart, to: WarmUI.indicatorCausticEnd)
                .stroke(
                    WarmUI.indicatorCaustic,
                    style: StrokeStyle(
                        lineWidth: WarmUI.indicatorCausticWidth,
                        lineCap: .round))
                .padding(WarmUI.indicatorCausticPadding)

            Circle()
                .trim(from: 0, to: model.progress)
                .stroke(
                    WarmUI.indicatorMoltenRim,
                    style: StrokeStyle(
                        lineWidth: WarmUI.indicatorMoltenRimWidth,
                        lineCap: .round))
                .opacity(WarmUI.indicatorMoltenRimOpacity)
                .rotationEffect(.degrees(-90))
                .padding(WarmUI.indicatorMoltenPadding)

            Circle()
                .trim(from: 0, to: model.progress)
                .stroke(
                    WarmUI.indicatorMoltenBody,
                    style: StrokeStyle(
                        lineWidth: WarmUI.indicatorMoltenBodyWidth,
                        lineCap: .round))
                .opacity(WarmUI.indicatorMoltenBodyOpacity)
                .rotationEffect(.degrees(-90))
                .padding(WarmUI.indicatorMoltenPadding)

            Circle()
                .trim(from: 0, to: model.progress)
                .stroke(
                    WarmUI.indicatorMoltenCore,
                    style: StrokeStyle(
                        lineWidth: WarmUI.indicatorMoltenCoreWidth,
                        lineCap: .round))
                .opacity(WarmUI.indicatorMoltenCoreOpacity)
                .rotationEffect(.degrees(-90))
                .padding(WarmUI.indicatorMoltenPadding)

            Circle()
                .trim(from: 0, to: model.progress)
                .stroke(
                    WarmUI.indicatorMoltenSpecular,
                    style: StrokeStyle(
                        lineWidth: WarmUI.indicatorMoltenSpecularWidth,
                        lineCap: .round))
                .opacity(WarmUI.indicatorMoltenSpecularOpacity)
                .rotationEffect(.degrees(-90))
                .padding(WarmUI.indicatorMoltenSpecularPadding)

            if let icon = model.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 26, height: 26)
                    .opacity(0.45 + 0.55 * model.progress)
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        .padding(1)
    }
}
