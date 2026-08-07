import Foundation

/// Headless recording mode. The same binary runs with `--daemon` under a LaunchAgent
/// so history keeps accruing while the UI is closed — the only way to answer
/// "what drained the battery overnight?" after the fact.
enum BackgroundSampler {
    static let label = "com.ivogundlach.vitals.sampler"
    /// 30s matches the history store's resolution; finer sampling would cost more
    /// energy than it explains.
    static let interval: TimeInterval = 30

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Runs until killed. Keeps one engine alive so deltas stay continuous.
    static func runDaemon() -> Never {
        let engine = VitalsEngine()
        let store = HistoryStore()
        var lastPrune = Date.distantPast
        let retention = UserDefaults.standard.object(forKey: "retentionDays") as? Int ?? 14

        _ = engine.sampleOnce()          // prime: first sample has no deltas
        while true {
            Thread.sleep(forTimeInterval: interval)
            // If the user has installed the privileged helper, fold its counters in
            // so while-quit history can attribute drain to root daemons too — the
            // exact processes that hide overnight battery drain.
            if HelperManager.status() == .installed {
                engine.setPrivilegedCounters(HelperManager.readCounters())
            }
            let snapshot = engine.sampleOnce()
            store?.record(snapshot)
            if Date().timeIntervalSince(lastPrune) > 3600 {
                lastPrune = Date()
                store?.prune(retaining: retention)
            }
        }
    }

    static func install() throws {
        let executable = Bundle.main.executableURL?.path
            ?? "/Applications/Vitals.app/Contents/MacOS/Vitals"
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "--daemon"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 5,
        ]
        let dir = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                      format: .xml, options: 0)
        try data.write(to: plistURL)

        let uid = getuid()
        // bootout first so reinstalling picks up a changed executable path.
        _ = run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        let result = run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistURL.path])
        if result.status != 0 {
            throw NSError(domain: "Vitals", code: Int(result.status), userInfo: [
                NSLocalizedDescriptionKey:
                    "launchctl bootstrap failed: \(result.output.isEmpty ? "unknown error" : result.output)"
            ])
        }
    }

    static func uninstall() throws {
        _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
