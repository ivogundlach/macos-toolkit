import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var samplerEnabled = BackgroundSampler.isInstalled()
    @State private var samplerError: String?
    /// Mirrors SMAppService rather than a stored preference, so switching it off in
    /// System Settings shows up here too.
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var launchAtLoginError: String?

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            menuBar.tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            recording.tabItem { Label("Recording", systemImage: "record.circle") }
            access.tabItem { Label("Access", systemImage: "lock.shield") }
        }
        .frame(width: 460, height: 380)
    }

    private var general: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Refresh every")
                        Slider(value: $model.interval, in: 0.5...10, step: 0.5)
                        Text(Fmt.duration(model.interval))
                            .font(VitalsTheme.monoSmall).frame(width: 40, alignment: .trailing)
                    }
                    Text("Faster refresh costs a little CPU itself. 2 seconds is a good balance.")
                        .font(VitalsTheme.labelSmall).foregroundStyle(.secondary)
                }
            }
            Section("Appearance") {
                fontSizeControl("Main process-list font size",
                                value: $model.mainProcessFontSize,
                                description: "Changes process names, values, and column headings in the main app.")
            }
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Start at login", isOn: Binding(
                        get: { launchAtLogin },
                        set: { setLaunchAtLogin($0) }))
                    Text("Starts in the menu bar only — no window and no Dock icon. Opening "
                         + "Vitals yourself still opens the window as usual. This is the same "
                         + "switch as System Settings → General → Login Items.")
                        .font(VitalsTheme.labelSmall).foregroundStyle(.secondary)
                    if let launchAtLoginError {
                        Text(launchAtLoginError).font(VitalsTheme.labelSmall)
                            .foregroundStyle(VitalsTheme.critical)
                    }
                }
            }
            Section {
                Label("Vitals keeps running in the menu bar", systemImage: "menubar.arrow.up.rectangle")
                Text("Closing the window does not quit Vitals — it drops to the menu bar and "
                     + "keeps sampling. A Dock icon appears while the window is open; reopen it "
                     + "anytime from the menu bar. Use Quit in the menu bar dropdown to exit fully.")
                    .font(VitalsTheme.labelSmall).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // System Settings can change this behind the app's back.
        .onAppear { launchAtLogin = LoginItem.isEnabled }
    }

    private func setLaunchAtLogin(_ enable: Bool) {
        do {
            try LoginItem.setEnabled(enable)
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = LoginItem.isEnabled
    }

    private var menuBar: some View {
        Form {
            Section("Appearance") {
                fontSizeControl("Dropdown process-list font size",
                                value: $model.panelProcessFontSize,
                                description: "Changes process names, values, and headings in the menu bar dropdown.")
            }
            Section("Menu bar readout") {
                ForEach(MenuBarMetric.allCases) { metric in
                    Toggle(isOn: strip(metric)) { metricRow(metric) }
                }
                Toggle("Show labels next to values", isOn: $model.showMenuBarLabels)
                Text("Shown in the menu bar strip, in the order listed. Selecting many widens "
                     + "the item, which a notch can clip — two is a safe default.")
                    .font(VitalsTheme.labelSmall).foregroundStyle(.secondary)
            }
            Section("Dropdown panel — stat tiles") {
                ForEach(MenuBarMetric.allCases) { metric in
                    Toggle(isOn: panel(metric)) { metricRow(metric) }
                }
                Text("The big tiles at the top of the dropdown. These wrap, so pick as many as "
                     + "you like.")
                    .font(VitalsTheme.labelSmall).foregroundStyle(.secondary)
            }
            Section("Dropdown panel — lists") {
                ForEach(PanelProcessMetric.allCases) { metric in
                    Toggle(metric.title, isOn: processList(metric))
                }
                Picker("Processes per list", selection: $model.panelListSize) {
                    ForEach(PanelListSize.allCases) { Text($0.title).tag($0) }
                }
                Text("Each list reserves a fixed height so rows appearing and disappearing "
                     + "never move the buttons. “All” scrolls within the panel.")
                    .font(VitalsTheme.labelSmall).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func fontSizeControl(_ title: String, value: Binding<Double>,
                                 description: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) pt")
                    .font(VitalsTheme.monoSmall).foregroundStyle(.secondary)
            }
            Slider(value: value, in: 10...20, step: 1)
            Text(description)
                .font(VitalsTheme.labelSmall).foregroundStyle(.secondary)
        }
    }

    private func metricRow(_ metric: MenuBarMetric) -> some View {
        HStack(spacing: 5) {
            Image(systemName: metric.symbol).frame(width: 15)
            Text(metric.title)
            Spacer()
            Text(metric.render(model.snapshot))
                .font(VitalsTheme.monoSmall).foregroundStyle(.secondary)
        }
    }

    private var recording: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Record in the background", isOn: Binding(
                        get: { samplerEnabled },
                        set: { toggleSampler($0) }))
                    Text("Runs a small background job that records a sample every 30 seconds even "
                         + "when Vitals is closed. The Energy, CPU, GPU and Memory tabs are built "
                         + "entirely from these recordings, so this is what makes their week and "
                         + "month views — and overnight battery drain — answerable after the fact.")
                        .font(VitalsTheme.labelSmall).foregroundStyle(.secondary)
                    if let samplerError {
                        Text(samplerError).font(VitalsTheme.labelSmall)
                            .foregroundStyle(VitalsTheme.critical)
                    }
                }
            }
            Section {
                Picker("Keep history for", selection: $model.retentionDays) {
                    Text("3 days").tag(3)
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                Text("The Month view looks back 30 days, so anything shorter than that "
                     + "truncates it.")
                    .font(VitalsTheme.labelSmall).foregroundStyle(.secondary)
                HStack {
                    Text("Database")
                    Spacer()
                    Text(HistoryStore.defaultURL.path)
                        .font(VitalsTheme.monoSmall).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.defaultURL])
                }
            }
        }
        .formStyle(.grouped)
    }

    private var access: some View {
        Form {
            Section("Process visibility") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: model.snapshot.unreadableProcesses > 0
                              ? "lock.fill" : "lock.open.fill")
                            .foregroundStyle(model.snapshot.unreadableProcesses > 0
                                             ? VitalsTheme.warn : VitalsTheme.ok)
                        Text("\(model.snapshot.totalProcesses - model.snapshot.unreadableProcesses) "
                             + "of \(model.snapshot.totalProcesses) processes fully measured")
                        Spacer()
                    }
                    Text("macOS refuses per-process CPU, energy and disk counters for processes "
                         + "owned by another user — mostly root daemons such as mdworker_shared "
                         + "and backupd. Their names are visible, but their numbers are not. "
                         + "A privileged helper closes that gap.")
                        .font(VitalsTheme.labelSmall).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HelperSettingsView()
                }
            }
            Section("What works without any helper") {
                VStack(alignment: .leading, spacing: 3) {
                    bullet("Per-process energy in real milliwatts, plus performance-core share")
                    bullet("Per-process GPU time, from Metal command-queue accounting")
                    bullet("GPU rail power, utilisation, and VRAM")
                    bullet("Whole-system watts, battery health and cycle count")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "checkmark").font(.system(size: 8)).foregroundStyle(VitalsTheme.ok)
                .padding(.top, 2)
            Text(text).font(VitalsTheme.labelSmall)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func strip(_ metric: MenuBarMetric) -> Binding<Bool> {
        toggle(metric, keyPath: \.menuBarMetrics)
    }

    private func panel(_ metric: MenuBarMetric) -> Binding<Bool> {
        toggle(metric, keyPath: \.panelMetrics)
    }

    private func processList(_ metric: PanelProcessMetric) -> Binding<Bool> {
        Binding(
            get: { model.panelProcessMetrics.contains(metric) },
            set: { isOn in
                if isOn {
                    if !model.panelProcessMetrics.contains(metric) {
                        model.panelProcessMetrics.append(metric)
                    }
                } else {
                    model.panelProcessMetrics.removeAll { $0 == metric }
                }
            })
    }

    /// Add/remove a metric from one of the model's ordered metric lists.
    private func toggle(_ metric: MenuBarMetric,
                        keyPath: ReferenceWritableKeyPath<AppModel, [MenuBarMetric]>) -> Binding<Bool> {
        Binding(
            get: { model[keyPath: keyPath].contains(metric) },
            set: { isOn in
                if isOn {
                    if !model[keyPath: keyPath].contains(metric) { model[keyPath: keyPath].append(metric) }
                } else {
                    model[keyPath: keyPath].removeAll { $0 == metric }
                }
            })
    }

    private func toggleSampler(_ enable: Bool) {
        do {
            if enable { try BackgroundSampler.install() } else { try BackgroundSampler.uninstall() }
            samplerEnabled = BackgroundSampler.isInstalled()
            samplerError = nil
        } catch {
            samplerError = error.localizedDescription
            samplerEnabled = BackgroundSampler.isInstalled()
        }
    }
}
