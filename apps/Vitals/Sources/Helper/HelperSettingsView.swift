import SwiftUI

/// Install/remove UI for the optional privileged helper. States exactly what the
/// helper does and what it costs, because it is a root daemon and the user should
/// be able to decide with the facts in front of them.
struct HelperSettingsView: View {
    @State private var status = HelperManager.status()
    @State private var busy = false
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(statusText).font(VitalsTheme.label)
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button(status == .notInstalled ? "Enable Full Visibility…" : "Remove Helper…") {
                        toggle()
                    }
                    .controlSize(.small)
                }
            }

            if status == .notInstalled {
                VStack(alignment: .leading, spacing: 2) {
                    detail("Installs a root background service that reads process counters "
                           + "and publishes them to a single read-only file.")
                    detail("It takes no input, opens no network or IPC channel, and performs no "
                           + "action other than reading kernel counters.")
                    detail("Requires one administrator authorisation. Removable at any time.")
                }
            }

            if let message {
                Text(message)
                    .font(VitalsTheme.labelSmall)
                    .foregroundStyle(isError ? VitalsTheme.critical : VitalsTheme.ok)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { status = HelperManager.status() }
    }

    private func detail(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Text("•").font(VitalsTheme.labelSmall).foregroundStyle(.secondary)
            Text(text).font(VitalsTheme.labelSmall).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var statusColor: Color {
        switch status {
        case .installed: return VitalsTheme.ok
        case .installedButStale: return VitalsTheme.warn
        case .notInstalled: return .secondary
        }
    }

    private var statusText: String {
        switch status {
        case .installed: return "Helper active — all processes measurable"
        case .installedButStale: return "Helper installed but not publishing"
        case .notInstalled: return "Helper not installed — root processes unmeasured"
        }
    }

    private func toggle() {
        busy = true
        message = nil
        let installing = status == .notInstalled
        DispatchQueue.global(qos: .userInitiated).async {
            var result: String?
            var failed = false
            do {
                if installing {
                    try HelperManager.install(fromBundle: HelperManager.bundledHelperURL())
                    result = "Helper installed. Root-owned processes will populate within a few seconds."
                } else {
                    try HelperManager.uninstall()
                    result = "Helper removed."
                }
            } catch {
                result = error.localizedDescription
                failed = true
            }
            DispatchQueue.main.async {
                busy = false
                message = result
                isError = failed
                status = HelperManager.status()
            }
        }
    }
}
