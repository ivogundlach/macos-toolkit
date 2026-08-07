// Faceless host app for CLT builds: no window, no Dock icon, no menu bar.
// Its only job is to (re)register the Safari extension appex, then exit.
import AppKit

final class AppDelegateCLT: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            NSApp.terminate(nil)
        }
    }
}

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegateCLT()
        app.delegate = delegate
        app.setActivationPolicy(.prohibited)
        app.run()
    }
}
