import Foundation

/// App-side control of the optional privileged helper.
///
/// The helper exists solely because macOS denies `proc_pid_rusage` for processes
/// owned by another user. It is deliberately the smallest thing that can close that
/// gap: a root LaunchDaemon that reads kernel counters and writes them to one
/// world-readable file. It parses no arguments, opens no sockets, and accepts no
/// input from the app, so there is no channel for the unprivileged side to
/// influence what it does.
enum HelperManager {
    static let label = "com.ivogundlach.vitals.helper"
    static let binaryPath = "/Library/PrivilegedHelperTools/\(label)"
    static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    /// Where the helper publishes counters. World-readable, root-writable only.
    static let counterPath = "/var/run/vitals-counters.json"

    enum Status {
        case notInstalled
        case installed
        case installedButStale     // present but has not published recently
    }

    static func status() -> Status {
        guard FileManager.default.fileExists(atPath: binaryPath),
              FileManager.default.fileExists(atPath: plistPath) else { return .notInstalled }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: counterPath),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < 60 else { return .installedButStale }
        return .installed
    }

    private static let cacheLock = NSLock()
    private static var cachedMtime: Date?
    private static var cachedCounters: [Int32: ProcCounters] = [:]

    /// Counters published by the helper, keyed by pid.
    ///
    /// The helper rewrites the file every few seconds while the app samples faster,
    /// so re-parsing ~640 JSON entries on every sample is wasted work. Parse only
    /// when the file's modification time actually changes; otherwise return the
    /// cached result.
    static func readCounters() -> [Int32: ProcCounters] {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: counterPath))?[.modificationDate] as? Date
        cacheLock.lock()
        if let mtime, mtime == cachedMtime {
            defer { cacheLock.unlock() }
            return cachedCounters
        }
        cacheLock.unlock()

        guard let data = FileManager.default.contents(atPath: counterPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["processes"] as? [[String: Any]] else { return [:] }

        var out: [Int32: ProcCounters] = [:]
        out.reserveCapacity(list.count)
        for entry in list {
            guard let pid = entry["pid"] as? Int else { continue }
            var c = ProcCounters()
            c.pid = Int32(pid)
            c.cpuNs = u64(entry["cpu_ns"])
            c.pCpuNs = u64(entry["pcpu_ns"])
            c.energyNj = u64(entry["energy_nj"])
            c.pEnergyNj = u64(entry["penergy_nj"])
            c.cycles = u64(entry["cycles"])
            c.instructions = u64(entry["instructions"])
            c.idleWakeups = u64(entry["idle_wkups"])
            c.interruptWakeups = u64(entry["intr_wkups"])
            c.diskRead = u64(entry["disk_r"])
            c.diskWrite = u64(entry["disk_w"])
            c.footprint = u64(entry["footprint"])
            c.resident = u64(entry["resident"])
            out[Int32(pid)] = c
        }
        cacheLock.lock()
        cachedMtime = mtime
        cachedCounters = out
        cacheLock.unlock()
        return out
    }

    /// Installs the helper. Requires one administrator authorisation.
    ///
    /// Ownership matters more than anything else here: a root-launched binary that
    /// a non-root user can overwrite is a root code-execution hole, so the install
    /// script sets root:wheel ownership and strips group/other write before the
    /// daemon is ever bootstrapped.
    static func install(fromBundle helperSource: URL) throws {
        guard FileManager.default.fileExists(atPath: helperSource.path) else {
            throw error("Helper binary missing from the app bundle at \(helperSource.path).")
        }
        let script = """
            set -e
            /bin/mkdir -p /Library/PrivilegedHelperTools
            /bin/cp -f '\(helperSource.path)' '\(binaryPath)'
            /usr/sbin/chown root:wheel '\(binaryPath)'
            /bin/chmod 755 '\(binaryPath)'
            /bin/cp -f '\(plistSourcePath())' '\(plistPath)'
            /usr/sbin/chown root:wheel '\(plistPath)'
            /bin/chmod 644 '\(plistPath)'
            /bin/launchctl bootout system/\(label) 2>/dev/null || true
            /bin/launchctl bootstrap system '\(plistPath)'
            """
        try runPrivileged(script, prompt: "Vitals needs administrator access to install its "
                          + "process-monitoring helper.")
    }

    static func uninstall() throws {
        let script = """
            /bin/launchctl bootout system/\(label) 2>/dev/null || true
            /bin/rm -f '\(binaryPath)' '\(plistPath)' '\(counterPath)'
            """
        try runPrivileged(script, prompt: "Vitals needs administrator access to remove its "
                          + "process-monitoring helper.")
    }

    /// Written next to the helper inside the bundle at build time.
    private static func plistSourcePath() -> String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons/\(label).plist").path
    }

    static func bundledHelperURL() -> URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/PrivilegedHelperTools/\(label)")
    }

    /// One authorisation prompt via AppleScript. The script is a fixed string with
    /// no user-supplied interpolation.
    private static func runPrivileged(_ script: String, prompt: String) throws {
        let source = """
            do shell script "\(script.replacingOccurrences(of: "\\", with: "\\\\")
                                     .replacingOccurrences(of: "\"", with: "\\\"")
                                     .replacingOccurrences(of: "\n", with: " ; "))" \
            with prompt "\(prompt)" with administrator privileges
            """
        var errorInfo: NSDictionary?
        guard let apple = NSAppleScript(source: source) else {
            throw error("Could not construct the installation script.")
        }
        apple.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            let number = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            if number == -128 { throw error("Authorisation cancelled.") }
            throw error(message)
        }
    }

    private static func u64(_ any: Any?) -> UInt64 {
        if let n = any as? NSNumber { return UInt64(max(0, n.int64Value)) }
        return 0
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "Vitals.Helper", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
