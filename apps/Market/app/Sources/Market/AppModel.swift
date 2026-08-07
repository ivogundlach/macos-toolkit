import Foundation
import SwiftUI

// Central observable app state. Holds backend paths/settings, the appctl bridge,
// the read repository, and the live command-state for the UI. Reads run on a
// background queue; appctl calls run off the main thread via the actor.

@MainActor
final class AppModel: ObservableObject {
    // ROOT is stored in app settings (CONTRACTS.md §6) and all paths resolve from it.
    #if IVO_PREVIEW
    // Preview builds are separate QA artifacts. Their root is explicitly disposable
    // and never reads or writes the production UserDefaults key.
    @Published var root: String = ProcessInfo.processInfo.environment["MARKET_PREVIEW_ROOT"]
        ?? (NSTemporaryDirectory() + "MarketPreview")
    #else
    @AppStorage("marketRoot") var root: String = "/Users/YOUR_USERNAME/Projects/Market"
    #endif

    @Published var paths: BackendPaths
    @Published var appctl: AppCtl
    @Published var repo: Repository
    @Published var config: ConfigStore

    // Schema gate + backend availability surfaced to all views.
    @Published var meta: Meta?
    @Published var schemaError: String?
    @Published var backendReady: Bool = false

    // Last known generation from appctl, for staleness detection (CONTRACTS.md §1).
    @Published var generation: Int?
    // Bumps whenever a write succeeds; views observe to reload reads.
    @Published var dataRevision: Int = 0

    // Most recent command state for the global status banner.
    @Published var lastCommand: CommandState = .idle
    @Published var lastCommandLabel: String = ""

    // Ticker drilldown: clicking a ticker anywhere (Overview Top Picks,
    // Recommendations tables/search, Today's signals) sets this. While non-nil
    // the detail pane shows the Ticker Detail drilldown with a Back affordance,
    // regardless of the sidebar selection. Ticker Detail is no longer a sidebar
    // screen — it is reached only via this drilldown.
    @Published var drilldownTicker: String?

    /// Open the Ticker Detail drilldown for `ticker` from anywhere in the app.
    func openTicker(_ ticker: String) {
        let t = ticker.trimmingCharacters(in: .whitespaces).uppercased()
        guard !t.isEmpty else { return }
        drilldownTicker = t
    }

    /// Dismiss the ticker drilldown and return to the selected sidebar screen.
    func closeTicker() { drilldownTicker = nil }

    // Delivers backend outbox rows as native push notifications (sole surface;
    // email retired 2026-07-01). Owned here so it survives view churn.
    let notifier: Notifier

    init() {
        #if IVO_PREVIEW
        let r = ProcessInfo.processInfo.environment["MARKET_PREVIEW_ROOT"]
            ?? (NSTemporaryDirectory() + "MarketPreview")
        #else
        let r = UserDefaults.standard.string(forKey: "marketRoot") ?? "/Users/YOUR_USERNAME/Projects/Market"
        #endif
        let p = BackendPaths(root: r)
        self.paths = p
        let ctl = AppCtl(paths: p)
        self.appctl = ctl
        self.repo = Repository(paths: p)
        self.config = ConfigStore(paths: p)
        self.notifier = Notifier(appctl: ctl)
        refreshBackendStatus()
        notifier.start()
    }

    /// Re-derive paths/services after the user edits ROOT in Settings.
    func applyRoot(_ newRoot: String) {
        #if IVO_PREVIEW
        guard newRoot == root else {
            failCommand(label: "Change ROOT", message: "ROOT changes are disabled in the isolated preview build.")
            return
        }
        #endif
        root = newRoot
        let p = BackendPaths(root: newRoot)
        paths = p
        appctl = AppCtl(paths: p)
        repo = Repository(paths: p)
        config = ConfigStore(paths: p)
        notifier.update(appctl: appctl)
        refreshBackendStatus()
        dataRevision += 1
    }

    func refreshBackendStatus() {
        #if IVO_PREVIEW
        // The preview command bridge is in-process; repository reads still point
        // only at MARKET_PREVIEW_ROOT's disposable fixture database.
        backendReady = true
        #else
        backendReady = appctl.backendAvailable()
        #endif
        do {
            let m = try repo.loadMeta()
            meta = m
            generation = m.generation
            schemaError = m.compatible ? nil
                : "Backend needs migration: DB schema v\(m.schemaVersion), app supports v\(Meta.appSchema)."
        } catch {
            meta = nil
            schemaError = "\(error)"
        }
    }

    /// True when reads are safe (schema in range). Views show the migration
    /// placeholder otherwise.
    var canRead: Bool { schemaError == nil }

    /// Run an appctl command with full command-state lifecycle + staleness update.
    func runCommand(_ label: String, _ cmd: String,
                    args: [String: JSONValue] = [:],
                    recomputes: Bool = false) async {
        lastCommandLabel = label
        lastCommand = .queued
        lastCommand = .running
        #if IVO_PREVIEW
        // Visual/interaction QA exercises the full command-state lifecycle without
        // spawning appctl or touching live configuration/database state.
        generation = (generation ?? 0) + 1
        lastCommand = .succeeded(generation: generation)
        dataRevision += 1
        return
        #else
        do {
            let resp = try await appctl.run(cmd, args: args)
            if resp.isOK {
                if let g = resp.generation { generation = g }
                lastCommand = .succeeded(generation: resp.generation)
                // Any write may have changed reads.
                dataRevision += 1
                refreshBackendStatus()
            } else {
                let msg = "[\(resp.code ?? "ERROR")] \(resp.message ?? "command failed")"
                lastCommand = .failed(message: msg)
            }
        } catch {
            lastCommand = .failed(message: "\(error)")
        }
        #endif
    }

    /// Run one appctl command as part of a bulk import: returns success without
    /// per-row UI churn (no status flicker, no reload). Caller batches the final
    /// status + reload via `finishImport`.
    func importRun(_ cmd: String, args: [String: JSONValue]) async -> Bool {
        #if IVO_PREVIEW
        generation = (generation ?? 0) + 1
        return true
        #else
        do {
            let resp = try await appctl.run(cmd, args: args)
            if resp.isOK, let g = resp.generation { generation = g }
            return resp.isOK
        } catch {
            return false
        }
        #endif
    }

    /// Finalize a bulk import: one reload + a single status-bar summary.
    func finishImport(label: String, imported: Int, failed: Int) {
        dataRevision += 1
        refreshBackendStatus()
        lastCommandLabel = label
        lastCommand = failed == 0
            ? .succeeded(generation: generation)
            : .failed(message: "\(imported) imported, \(failed) failed")
    }

    /// Surface a command failure when a caller intentionally used a quiet
    /// prerequisite command and must not continue after it fails.
    func failCommand(label: String, message: String) {
        refreshBackendStatus()
        lastCommandLabel = label
        lastCommand = .failed(message: message)
    }
}

// Background read helper: run a throwing read off-main and deliver on main.
func loadAsync<T>(_ work: @escaping () throws -> T) async -> Result<T, Error> {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async {
            do { cont.resume(returning: .success(try work())) }
            catch { cont.resume(returning: .failure(error)) }
        }
    }
}
