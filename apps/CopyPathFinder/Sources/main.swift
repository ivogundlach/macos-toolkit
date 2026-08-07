import Cocoa

// Minimal background host app for the FinderSync extension.
// Launching it once registers the extension with pluginkit; it then quits.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
    app.terminate(nil)
}
app.run()
