import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: CornerSettings
    let onPreview: (Corner) -> Void

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    @Namespace private var glass

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            // Laid out the way the corners sit on the screen. The container lets the
            // four cards sample the backdrop as one surface instead of four.
            GlassEffectContainer(spacing: 12) {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach([Corner.topLeft, .topRight, .bottomLeft, .bottomRight]) { corner in
                        CornerCard(
                            corner: corner,
                            action: binding(for: corner),
                            onPreview: { onPreview(corner) })
                            .glassEffectID(corner, in: glass)
                    }
                }
            }

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 560)
        .refractiveCanvas()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Warm Corners").font(.system(size: 15, weight: .semibold))
                Text("Rest the pointer in a corner for its delay, then the app opens.")
                    .font(WarmUI.label).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Pause", isOn: $settings.isPaused)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Toggle("Start at login", isOn: $settings.launchAtLogin)
                .toggleStyle(.checkbox)
            Toggle("Show countdown", isOn: $settings.showIndicator)
                .toggleStyle(.checkbox)
            Spacer()
            Button("Quit Warm Corners") { NSApp.terminate(nil) }
                .buttonStyle(.glass)
        }
        .font(WarmUI.label)
    }

    private func binding(for corner: Corner) -> Binding<CornerAction> {
        Binding(
            get: { settings.action(for: corner) },
            set: { settings.setAction($0, for: corner) })
    }
}

private struct CornerCard: View {
    let corner: Corner
    @Binding var action: CornerAction
    let onPreview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                CornerGlyph(corner: corner, active: action.isActive)
                Text(corner.label).font(WarmUI.title)
                Spacer()
            }

            appPicker

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Delay").font(WarmUI.label).foregroundStyle(.secondary)
                    Spacer()
                    Text(delayText).font(WarmUI.value).monospacedDigit()
                }
                Slider(value: $action.delay, in: 0...3, step: 0.05) { editing in
                    if !editing { onPreview() }
                }
                .controlSize(.small)
                .disabled(!action.isActive)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .refractiveGlass(cornerRadius: WarmUI.cardRadius)
        .animation(.snappy(duration: 0.2), value: action.isActive)
    }

    private var delayText: String {
        action.delay < 0.025 ? "Instant" : String(format: "%.2f s", action.delay)
    }

    private var appPicker: some View {
        Menu {
            Button("None") { action.appPath = nil }
            Divider()
            ForEach(AppCatalog.apps) { entry in
                Button(entry.name) { action.appPath = entry.path }
            }
            Divider()
            Button("Choose…") { chooseApp() }
        } label: {
            HStack(spacing: 6) {
                if let url = action.appURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable().frame(width: 16, height: 16)
                }
                Text(action.appName ?? "None")
                    .foregroundStyle(action.isActive ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        // Stays a solid inset: glass inside glass muddies both layers.
        .background(WarmUI.inset, in: RoundedRectangle(cornerRadius: WarmUI.controlRadius))
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            action.appPath = url.path
        }
    }
}

/// A miniature screen with the relevant corner lit, so the grid reads at a glance.
private struct CornerGlyph: View {
    let corner: Corner
    let active: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2.5)
                .strokeBorder(Color.primary.opacity(0.35), lineWidth: 1)
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(active ? AnyShapeStyle(WarmUI.warmGradient) : AnyShapeStyle(Color.primary.opacity(0.2)))
                    .frame(width: geo.size.width / 2, height: geo.size.height / 2)
                    .position(
                        x: corner == .topLeft || corner == .bottomLeft ? geo.size.width / 4 : geo.size.width * 0.75,
                        y: corner == .topLeft || corner == .topRight ? geo.size.height / 4 : geo.size.height * 0.75)
            }
            .padding(2)
        }
        .frame(width: 20, height: 14)
    }
}
