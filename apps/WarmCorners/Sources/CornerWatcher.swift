import AppKit

/// Watches the pointer and fires a corner's action once the pointer has rested
/// there for that corner's delay.
///
/// Driven by mouse-moved events rather than a poll, so a still pointer costs
/// nothing; the only timer that ever runs is the one counting out a dwell.
@MainActor
final class CornerWatcher {
    /// How close to the corner counts as "in it".
    private let hotSize: CGFloat = 6
    /// How far back out the pointer has to travel before the same corner can fire
    /// again. Larger than `hotSize` so pointer jitter cannot double-fire.
    private let releaseSize: CGFloat = 40
    private let tick = 1.0 / 60.0

    private let settings: CornerSettings
    private let indicator: IndicatorWindow

    private var monitors: [Any] = []
    private var dwellTimer: Timer?
    private var dwell: (corner: Corner, screen: NSScreen, start: Date)?
    /// Corner that already fired; blocked until the pointer leaves its release zone.
    private var fired: (corner: Corner, screen: NSScreen)?

    init(settings: CornerSettings, indicator: IndicatorWindow) {
        self.settings = settings
        self.indicator = indicator
    }

    func start() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) {
            monitors.append(global)
        }
        // Global monitors go quiet while our own Settings window is frontmost.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func pointerMoved() {
        let location = NSEvent.mouseLocation

        if let fired {
            // Stay latched until the pointer clearly leaves the corner it triggered.
            if fired.corner.contains(location, on: fired.screen, size: releaseSize) { return }
            self.fired = nil
        }

        guard !settings.isPaused, let hit = cornerHit(at: location) else {
            cancelDwell()
            return
        }
        guard settings.action(for: hit.corner).isActive else {
            cancelDwell()
            return
        }
        if let dwell, dwell.corner == hit.corner, dwell.screen == hit.screen { return }

        beginDwell(corner: hit.corner, screen: hit.screen)
    }

    private func cornerHit(at location: CGPoint) -> (corner: Corner, screen: NSScreen)? {
        for screen in NSScreen.screens {
            for corner in Corner.allCases where corner.contains(location, on: screen, size: hotSize) {
                return (corner, screen)
            }
        }
        return nil
    }

    private func beginDwell(corner: Corner, screen: NSScreen) {
        cancelDwell()
        let action = settings.action(for: corner)
        guard action.delay > 0 else {
            trigger(corner: corner, screen: screen)
            return
        }

        dwell = (corner, screen, Date())
        if settings.showIndicator {
            indicator.show(corner: corner, screen: screen, appURL: action.appURL)
        }
        dwellTimer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.dwellTick() }
        }
    }

    private func dwellTick() {
        guard let dwell else { return }
        // The pointer can leave without any event reaching us (space switch, warp),
        // so confirm it is still in the corner on every tick.
        guard dwell.corner.contains(NSEvent.mouseLocation, on: dwell.screen, size: hotSize) else {
            cancelDwell()
            return
        }

        let delay = settings.action(for: dwell.corner).delay
        let progress = Date().timeIntervalSince(dwell.start) / max(delay, 0.001)
        if progress >= 1 {
            trigger(corner: dwell.corner, screen: dwell.screen)
        } else {
            indicator.update(progress: progress)
        }
    }

    private func trigger(corner: Corner, screen: NSScreen) {
        cancelDwell()
        fired = (corner, screen)
        guard let url = settings.action(for: corner).appURL else { return }

        NSLog("WarmCorners: %@ fired -> %@", corner.label, url.lastPathComponent)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                NSLog("WarmCorners: could not open %@: %@", url.path, String(describing: error))
            }
        }
    }

    private func cancelDwell() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        dwell = nil
        indicator.hide()
    }

    /// Preview the countdown from Settings without having to reach for the corner.
    func demo(corner: Corner) {
        guard let screen = NSScreen.main else { return }
        let action = settings.action(for: corner)
        indicator.show(corner: corner, screen: screen, appURL: action.appURL)
        let duration = max(action.delay, 0.6)
        let start = Date()
        cancelDwellTimerOnly()
        dwellTimer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return }
                let progress = Date().timeIntervalSince(start) / duration
                if progress >= 1 {
                    timer.invalidate()
                    self.dwellTimer = nil
                    self.indicator.hide()
                } else {
                    self.indicator.update(progress: progress)
                }
            }
        }
    }

    private func cancelDwellTimerOnly() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        dwell = nil
    }
}
