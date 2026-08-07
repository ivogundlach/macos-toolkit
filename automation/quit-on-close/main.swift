// quit-on-close — small event-driven macOS behavior fixes.
//
// 1. Quit a regular (Dock) app when the USER closes its last window.
// Recreates Supercharge's "Quit an app when closing its last window", using the
// same event-driven design as Supercharge (verified from its binary's strings):
// react ONLY to explicit close actions — ⌘W key release and clicks on a window's
// red close button (AXCloseButton subrole) — then re-check the app's real window
// count (via CGWindowList, like Supercharge) up to 5 times and quit only if it
// reaches zero. Never infer anything from an event alone: minimize, hide, other
// Spaces, and programmatic closes don't trigger checks, and a surviving on-screen
// window (e.g. MovieBox Pro's main window after its video player closes) blocks
// the quit.
// Exclusions: bundle IDs, one per line, ~/.config/quit-on-close/exclude.txt
// ('#' inline comments allowed; file is reloaded before every check).
// Build/install/restart: ./build.sh
// (signing with the stable identity keeps the Accessibility grant across rebuilds)
// Needs Accessibility (prompts on first run; idles + retries until granted).
// Runs as LaunchAgent com.ivogundlach.quit-on-close. Log: ~/.local/state/quit-on-close/daemon.log
//
// 2. Prevent an otherwise-unhandled Play media key from leaving Apple Music open.
// The key always passes through so macOS can route it to Safari, Codex, or any other
// media app. If that key instead causes Music to auto-launch, quit it immediately.
import AppKit
import ApplicationServices

let excludeFile = ("~/.config/quit-on-close/exclude.txt" as NSString).expandingTildeInPath
var exclusions = Set<String>()
var excludeMtime = Date.distantPast

func reloadExclusions() {
    guard let mtime = (try? FileManager.default.attributesOfItem(atPath: excludeFile))?[.modificationDate] as? Date,
          mtime != excludeMtime,
          let text = try? String(contentsOfFile: excludeFile, encoding: .utf8) else { return }
    excludeMtime = mtime
    exclusions = Set(text.split(whereSeparator: \.isNewline)
        .map { $0.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty })
}

// Never auto-quit these regardless of the exclusion file.
let builtinSkip: Set<String> = ["com.apple.finder"]

let systemWide = AXUIElementCreateSystemWide()

// Count an app's real, user-facing windows the way Supercharge does (verified from
// its binary: CGWindowListCopyWindowInfo + kCGWindowOwnerPID/Layer/Alpha/IsOnscreen),
// NOT kAXWindowsAttribute. Some toolkits (MovieBox Pro) under-report real windows to
// AX — after closing a secondary window AX returned 0 while the main window was still
// on screen, so the app was wrongly quit. The window server does not lie about this.
// A window counts if it is on-screen, in the normal window layer (0), and not
// transparent (alpha > 0 drops the alpha-0 phantom title/toolbar surfaces the server
// also lists). Minimized windows aren't on-screen, so they're added separately via AX
// (additive only — an AX miss can never cause a false quit, only a missed one).
func realWindowCount(_ pid: pid_t) -> Int {
    let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    var count = 0
    for w in info where w[kCGWindowOwnerPID as String] as? pid_t == pid {
        let layer = w[kCGWindowLayer as String] as? Int ?? -1
        let alpha = w[kCGWindowAlpha as String] as? Double ?? 0
        if layer == 0 && alpha > 0 { count += 1 }
    }
    return count + minimizedWindowCount(pid)
}

// Count windows the app itself reports as minimized. macOS flips a minimized window's
// subrole to AXDialog and sets AXMinimized=true, so we key off AXMinimized directly
// (filtering by AXStandardWindow subrole would miss exactly these). Real phantoms
// (MovieBox's AXUnknown) report AXMinimized=false, so an app with only phantoms still
// counts as zero and can quit normally.
func minimizedWindowCount(_ pid: pid_t) -> Int {
    let el = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(el, 0.3)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else { return 0 }
    var n = 0
    for w in windows {
        var mini: CFTypeRef?
        AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &mini)
        if mini as? Bool == true { n += 1 }
    }
    return n
}

// MARK: - Quit check (runs only after an explicit user close action)

let workQ = DispatchQueue(label: "qoc.work") // all AX calls + state stay off the tap runloop

var checking = Set<pid_t>()

func scheduleQuitCheck(pid: pid_t, reason: String) {
    reloadExclusions()
    guard !checking.contains(pid),
          let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
          app.activationPolicy == .regular,
          let bid = app.bundleIdentifier,
          !exclusions.contains(bid), !builtinSkip.contains(bid) else { return }
    checking.insert(pid)
    quitCheck(app: app, bid: bid, reason: reason, attempt: 1)
}

func quitCheck(app: NSRunningApplication, bid: String, reason: String, attempt: Int) {
    workQ.asyncAfter(deadline: .now() + 0.5) {
        let pid = app.processIdentifier
        if app.isTerminated { checking.remove(pid); return }
        if realWindowCount(pid) == 0 {
            checking.remove(pid)
            NSLog("quitting %@ (%@, no windows left)", bid, reason)
            if bid == "com.ivogundlach.usagequeue" {
                // Its delivery workers are launchd-owned, so the UI can exit immediately.
                app.forceTerminate()
            } else {
                app.terminate()
            }
        } else if attempt >= 5 { // still has windows — give up
            checking.remove(pid)
        } else {
            quitCheck(app: app, bid: bid, reason: reason, attempt: attempt + 1)
        }
    }
}

// MARK: - Close-action detection (⌘W release, red close button click)

func keyIsW(_ event: CGEvent) -> Bool {
    if event.getIntegerValueField(.keyboardEventKeycode) == 13 { return true } // kVK_ANSI_W
    var length = 0
    var chars = [UniChar](repeating: 0, count: 4)
    event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
    return length > 0 && (chars[0] == 119 || chars[0] == 87) // w W
}

var cmdWTarget: pid_t = 0

func handleClick(at point: CGPoint) {
    var el: AXUIElement?
    guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &el) == .success,
          let el else { return }
    var subrole: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subrole) == .success,
          subrole as? String == kAXCloseButtonSubrole else { return }
    var pid: pid_t = 0
    guard AXUIElementGetPid(el, &pid) == .success else { return }
    scheduleQuitCheck(pid: pid, reason: "close button")
}

var eventTap: CFMachPort?

// MARK: - Play-key Music fallback cleanup

func isPlayMediaEvent(_ event: CGEvent) -> Bool {
    guard let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else { return false }
    let systemKey = (nsEvent.data1 & 0xffff0000) >> 16
    return systemKey == 16 // NX_KEYTYPE_PLAY
}

func mediaKeyState(_ event: CGEvent) -> Int? {
    guard let nsEvent = NSEvent(cgEvent: event) else { return nil }
    return (nsEvent.data1 & 0xff00) >> 8
}

func realMusicIsRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains {
        !$0.isTerminated && $0.bundleIdentifier == "com.apple.Music"
    }
}

var pendingMusicFallbackUntil = Date.distantPast

let musicLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didLaunchApplicationNotification,
    object: nil,
    queue: .main
) { note in
    guard Date() <= pendingMusicFallbackUntil,
          let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
          app.bundleIdentifier == "com.apple.Music" else { return }
    pendingMusicFallbackUntil = .distantPast
    NSLog("quitting Music auto-launched by an unhandled Play key")
    app.forceTerminate()
}

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    // CoreGraphics omits the public NSEventType.systemDefined case from its
    // Swift CGEventType overlay; its stable event type value is 14.
    if type.rawValue == 14, isPlayMediaEvent(event), let state = mediaKeyState(event) {
        if state == 0x0a, !realMusicIsRunning() {
            pendingMusicFallbackUntil = Date().addingTimeInterval(3)
        }
    }

    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
    case .keyDown:
        if event.flags.contains(.maskCommand) && keyIsW(event) {
            cmdWTarget = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        }
    case .keyUp:
        if cmdWTarget != 0 && keyIsW(event) {
            let pid = cmdWTarget
            cmdWTarget = 0
            workQ.async { scheduleQuitCheck(pid: pid, reason: "cmd-w") }
        }
    case .leftMouseDown:
        let loc = event.location
        workQ.async { handleClick(at: loc) } // AX hit-test off the tap path
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

func createTap() -> Bool {
    let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        | (1 << CGEventType.keyUp.rawValue)
        | (1 << CGEventType.leftMouseDown.rawValue)
        | (1 << 14) // NSEventType.systemDefined
    // Listen-only: this daemon observes events but can never swallow or alter them.
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                      options: .listenOnly, eventsOfInterest: mask,
                                      callback: tapCallback, userInfo: nil) else { return false }
    eventTap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

reloadExclusions()
AXUIElementSetMessagingTimeout(systemWide, 0.3)
let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
NSLog("started, %d exclusions, accessibility trusted: %d", exclusions.count, AXIsProcessTrustedWithOptions(prompt) ? 1 : 0)
if createTap() {
    NSLog("event tap active")
} else {
    NSLog("no accessibility permission yet; retrying every 5s")
    let retry = Timer(timeInterval: 5, repeats: true) { t in
        if createTap() {
            NSLog("event tap active")
            t.invalidate()
        }
    }
    RunLoop.main.add(retry, forMode: .common)
}
RunLoop.main.run()
