import AppKit
import SwiftUI
import KineticsCore

struct KineticsSettingsView: View {
    @ObservedObject var model: KineticsModel
    let quit: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var dockAnimationModel = DockAnimationModel()
    @State private var desktopSwitchingExpanded = true
    @State private var dockAnimationsExpanded = false
    @State private var engineStatusExpanded = false
    @State private var sessionExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KineticsUI.Space.s24) {
                header
                animationsArea
                appSettingsArea
                Button("Quit Kinetics", action: quit)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            }
            .padding(KineticsUI.Space.s24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(KineticsUI.canvas)
        .frame(minWidth: 680, minHeight: 480)
        .onAppear { model.setMinimizeMode(forSystemReduceMotion: reduceMotion) }
        .onChange(of: reduceMotion) { _, newValue in
            model.setMinimizeMode(forSystemReduceMotion: newValue)
        }
    }

    private var animationsArea: some View {
        VStack(alignment: .leading, spacing: KineticsUI.Space.s12) {
            sectionTitle("ANIMATIONS", systemImage: "sparkles")
            desktopSwitchingModule
            dockAnimationsModule
        }
    }

    private var appSettingsArea: some View {
        VStack(alignment: .leading, spacing: KineticsUI.Space.s12) {
            sectionTitle("APP SETTINGS", systemImage: "slider.horizontal.3")
            permissionModule
            launchModule
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: KineticsUI.Space.s16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(KineticsUI.accentGradient)
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: KineticsUI.Space.s8) {
                Text("KINETICS")
                    .font(KineticsUI.kicker)
                    .foregroundStyle(KineticsUI.accent)
                Text("Animation Tuning")
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                Text("Tune macOS animation modules with one calibrated feel.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var desktopSwitchingModule: some View {
        DisclosureGroup(isExpanded: $desktopSwitchingExpanded) {
            desktopSwitchingContent
        } label: {
            desktopSwitchingHeader
        }
        .kineticsPanel()
    }

    private var desktopSwitchingHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: KineticsUI.Space.s8) {
            Label("Desktop Switching", systemImage: "waveform.path")
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer(minLength: KineticsUI.Space.s8)
            Text("\(model.targetLabel) · \(model.enabled ? "Enabled" : "Disabled") · \(model.state.label)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var desktopSwitchingContent: some View {
        VStack(alignment: .leading, spacing: KineticsUI.Space.s16) {
            sectionTitle("CRISP ENGINE", systemImage: "waveform.path")
            Toggle("Enable Desktop Switching", isOn: $model.enabled)

            HStack(alignment: .firstTextBaseline) {
                Text(model.targetLabel)
                    .font(KineticsUI.metric)
                    .foregroundStyle(KineticsUI.accent)
                Text("target")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Crisp")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KineticsUI.accent)
                    .padding(.horizontal, KineticsUI.Space.s12)
                    .padding(.vertical, KineticsUI.Space.s4)
                    .background(KineticsUI.accent.opacity(0.14), in: Capsule())
            }

            Slider(value: $model.targetMilliseconds,
                   in: KineticsConstants.minimumTargetMilliseconds...KineticsConstants.maximumTargetMilliseconds,
                   step: 5)
            HStack {
                Text("Snappier")
                Spacer()
                Text("Balanced at 220 ms")
                Spacer()
                Text("Softer")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("The target is a calibrated approximation mapped to the DockSwipe ending velocity (currently ≈ \(model.velocityLabel)). The Dock owns final compositor travel and timing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle("Minimize spatial motion", isOn: $model.minimizeSpatialMotion)
            Text("Uses the proven high-velocity snap path to reduce visible travel. It does not independently control compositor fade.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Follow system Reduce Motion", isOn: $model.followReduceMotion)
            Text("When Reduce Motion is active, Kinetics switches through the same minimized-travel path. UI transitions also respect the system setting.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Trackpad Override", isOn: $model.trackpadOverride)
            Text("Applies the same Crisp target to configured horizontal trackpad Spaces swipe and commits once direction is clear, replacing Apple's interactive peek/cancel motion.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: KineticsUI.Space.s8) {
                Button { model.test(KineticsDirectionLeft, reduceMotion: reduceMotion) } label: {
                    Label("Test Left", systemImage: "arrow.left")
                }
                .disabled(!model.canTest)
                Button { model.test(KineticsDirectionRight, reduceMotion: reduceMotion) } label: {
                    Label("Test Right", systemImage: "arrow.right")
                }
                .disabled(!model.canTest)
                Spacer()
                Text(model.spaceLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !model.canTest {
                Text("Testing is unavailable until Kinetics is enabled and Accessibility plus the event tap are ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: KineticsUI.Space.s8) {
                Text("SHORTCUTS")
                    .font(KineticsUI.kicker)
                    .foregroundStyle(KineticsUI.accent)
                HStack {
                    Text("Left")
                    Spacer()
                    Text(model.shortcutResolution.left.displayLabel)
                        .font(.caption.monospaced())
                }
                HStack {
                    Text("Right")
                    Spacer()
                    Text(model.shortcutResolution.right.displayLabel)
                        .font(.caption.monospaced())
                }
                Text(model.shortcutResolution.statusLabel)
                    .font(.caption)
                    .foregroundStyle(model.shortcutResolution.usesFallback ? KineticsUI.warning : .secondary)
            }
        }
    }

    private var dockAnimationsModule: some View {
        DisclosureGroup(isExpanded: $dockAnimationsExpanded) {
            dockAnimationsContent
        } label: {
            dockAnimationsHeader
        }
        .kineticsPanel()
    }

    private var dockAnimationsHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: KineticsUI.Space.s8) {
            Label("Dock Animations", systemImage: "dock.rectangle")
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer(minLength: KineticsUI.Space.s8)
            Text(dockAnimationModel.currentSummary)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var dockAnimationsContent: some View {
        VStack(alignment: .leading, spacing: KineticsUI.Space.s16) {
            sectionTitle("DOCK ANIMATIONS", systemImage: "dock.rectangle")
            Text("Lower values are faster.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if dockAnimationModel.canEdit {
                dockAnimationControl("Dock reveal delay",
                                     value: $dockAnimationModel.revealDelay,
                                     range: KineticsConstants.DockAnimation.revealDelayRange)
                dockAnimationControl("Dock reveal/hide duration",
                                     value: $dockAnimationModel.revealHideDuration,
                                     range: KineticsConstants.DockAnimation.revealHideDurationRange)
                dockAnimationControl("Mission Control duration",
                                     value: $dockAnimationModel.missionControlDuration,
                                     range: KineticsConstants.DockAnimation.missionControlDurationRange)
            } else {
                Text("Current Dock values are unavailable; controls are disabled until all three preferences can be read.")
                    .font(.caption)
                    .foregroundStyle(KineticsUI.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if dockAnimationModel.hasDraftChanges {
                Text("Draft changes stay in memory until Apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: KineticsUI.Space.s8) {
                Button("Reload Current Values") {
                    dockAnimationModel.reloadCurrentValues()
                }
                .controlSize(.small)
                Spacer()
                Button("Apply & Restart Dock") {
                    dockAnimationModel.apply()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(!dockAnimationModel.canApply)
            }

            if let statusMessage = dockAnimationModel.statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(dockAnimationModel.statusIsError ? KineticsUI.danger : KineticsUI.success)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func dockAnimationControl(_ title: String,
                                      value: Binding<Double>,
                                      range: ClosedRange<Double>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: KineticsUI.Space.s12) {
            Text(title)
                .font(.body)
                .frame(minWidth: 190, alignment: .leading)
            Slider(value: value, in: range, step: 0.01)
                .accessibilityLabel(title)
                .accessibilityValue(String(format: "%.2f seconds", value.wrappedValue))
            Text(String(format: "%.2f s", value.wrappedValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(KineticsUI.accent)
                .frame(width: 58, alignment: .trailing)
        }
    }

    private var permissionModule: some View {
        DisclosureGroup(isExpanded: $engineStatusExpanded) {
            VStack(alignment: .leading, spacing: KineticsUI.Space.s12) {
                HStack(spacing: KineticsUI.Space.s8) {
                    Circle().fill(statusColor).frame(width: 9, height: 9)
                    Text(model.state.label).font(.headline)
                    Spacer()
                    Text(model.accessibilityTrusted ? "Accessibility trusted" : "Accessibility not trusted")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Kinetics never bypasses macOS privacy controls. Permission is checked here; no prompt is shown automatically at launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Accessibility Settings") { model.requestAccessibility() }
                    .controlSize(.small)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: KineticsUI.Space.s8) {
                Label("ENGINE STATUS", systemImage: "lock.shield")
                    .font(KineticsUI.kicker)
                    .foregroundStyle(KineticsUI.accent)
                Spacer(minLength: KineticsUI.Space.s8)
                Text(model.state.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .kineticsPanel()
    }

    private var launchModule: some View {
        DisclosureGroup(isExpanded: $sessionExpanded) {
            VStack(alignment: .leading, spacing: KineticsUI.Space.s12) {
                Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLogin },
                                                         set: { model.setLaunchAtLogin($0) }))
                Text("Uses a nested SMAppService login helper. Login starts the engine hidden and does not open Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = model.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(KineticsUI.danger)
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: KineticsUI.Space.s8) {
                Label("SESSION", systemImage: "power")
                    .font(KineticsUI.kicker)
                    .foregroundStyle(KineticsUI.accent)
                Spacer(minLength: KineticsUI.Space.s8)
                Text(model.launchAtLogin ? "Launch at Login enabled" : "Launch at Login disabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .kineticsPanel()
    }

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(KineticsUI.kicker)
            .foregroundStyle(KineticsUI.accent)
    }

    private var statusColor: Color {
        switch model.state {
        case .ready: return KineticsUI.success
        case .needsAccessibility, .inactive: return KineticsUI.warning
        case .disabled: return .secondary
        }
    }
}
