import AppKit
import CoreFoundation
import Darwin
import Foundation

private final class ExitStatusBox: @unchecked Sendable {
    var value: Int32 = 0
    var completed = false
}

/// The SMAppService login item is intentionally a tiny nested helper. It does
/// not own any settings or engine state; it only starts the main app hidden.
@main
struct KineticsLoginLauncher {
    static func main() {
        let mainAppURL = Bundle.main.bundleURL
            .deletingLastPathComponent() // LoginItems
            .deletingLastPathComponent() // Library
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // Kinetics.app

        guard FileManager.default.isReadableFile(atPath: mainAppURL.path) else {
            fputs("Kinetics Login Launcher: main app not found at \(mainAppURL.path)\n", stderr)
            Darwin.exit(1)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.hides = true
        configuration.promptsUserIfNeeded = false
        configuration.createsNewApplicationInstance = false
        configuration.arguments = ["--login"]

        let exitStatus = ExitStatusBox()
        NSWorkspace.shared.openApplication(at: mainAppURL, configuration: configuration) { _, error in
            if let error {
                fputs("Kinetics Login Launcher: \(error.localizedDescription)\n", stderr)
                exitStatus.value = 1
            }
            exitStatus.completed = true
        }

        let deadline = Date().addingTimeInterval(5)
        while !exitStatus.completed && Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.05, true)
        }
        if !exitStatus.completed {
            fputs("Kinetics Login Launcher: timed out waiting for launch\n", stderr)
            exitStatus.value = 1
        }
        Darwin.exit(exitStatus.value)
    }
}
