import AppKit
import Foundation

struct DockAnimationValues: Equatable {
    let revealDelay: Double
    let revealHideDuration: Double
    let missionControlDuration: Double

    static let initial = DockAnimationValues(
        revealDelay: KineticsConstants.DockAnimation.initialRevealDelay,
        revealHideDuration: KineticsConstants.DockAnimation.initialRevealHideDuration,
        missionControlDuration: KineticsConstants.DockAnimation.initialMissionControlDuration
    )

    var isFinite: Bool {
        revealDelay.isFinite &&
        revealHideDuration.isFinite &&
        missionControlDuration.isFinite
    }

    var isWithinSupportedRanges: Bool {
        isFinite &&
        KineticsConstants.DockAnimation.revealDelayRange.contains(revealDelay) &&
        KineticsConstants.DockAnimation.revealHideDurationRange.contains(revealHideDuration) &&
        KineticsConstants.DockAnimation.missionControlDurationRange.contains(missionControlDuration)
    }

    var summary: String {
        "Delay \(Self.format(revealDelay)) s · Reveal/hide \(Self.format(revealHideDuration)) s · Mission Control \(Self.format(missionControlDuration)) s"
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

enum DockAnimationReadError: LocalizedError {
    case preferencesUnavailable
    case missing(String)
    case nonNumeric(String)
    case nonFinite(String)
    case outOfRange(String)

    var errorDescription: String? {
        switch self {
        case .preferencesUnavailable:
            return "The com.apple.dock preferences domain is unavailable."
        case .missing(let key):
            return "Dock preference \(key) is missing."
        case .nonNumeric(let key):
            return "Dock preference \(key) is not numeric."
        case .nonFinite(let key):
            return "Dock preference \(key) is not finite."
        case .outOfRange(let detail):
            return "Dock preference values are outside Kinetics' supported ranges (\(detail))."
        }
    }
}

enum DockAnimationApplyError: LocalizedError {
    case preferencesUnavailable
    case synchronizationFailed
    case restartFailed(String)

    var errorDescription: String? {
        switch self {
        case .preferencesUnavailable:
            return "The com.apple.dock preferences domain is unavailable."
        case .synchronizationFailed:
            return "Dock preferences could not be synchronized. Dock was not restarted."
        case .restartFailed(let detail):
            return "Dock preferences were written, but Dock could not be restarted: \(detail)"
        }
    }
}

enum DockAnimationPreferences {
    static func readLiveValues() -> Result<DockAnimationValues, DockAnimationReadError> {
        guard let defaults = UserDefaults(suiteName: KineticsConstants.DockAnimation.preferencesDomain) else {
            return .failure(.preferencesUnavailable)
        }

        do {
            let values = DockAnimationValues(
                revealDelay: try readNumber(forKey: KineticsConstants.DockAnimation.revealDelayKey,
                                           from: defaults),
                revealHideDuration: try readNumber(forKey: KineticsConstants.DockAnimation.revealHideDurationKey,
                                                   from: defaults),
                missionControlDuration: try readNumber(forKey: KineticsConstants.DockAnimation.missionControlDurationKey,
                                                       from: defaults)
            )

            guard values.isWithinSupportedRanges else {
                let detail = "delay=\(values.revealDelay), reveal/hide=\(values.revealHideDuration), Mission Control=\(values.missionControlDuration)"
                return .failure(.outOfRange(detail))
            }
            return .success(values)
        } catch let error as DockAnimationReadError {
            return .failure(error)
        } catch {
            return .failure(.preferencesUnavailable)
        }
    }

    private static func readNumber(forKey key: String, from defaults: UserDefaults) throws -> Double {
        guard let object = defaults.object(forKey: key) else {
            throw DockAnimationReadError.missing(key)
        }
        guard let number = object as? NSNumber else {
            throw DockAnimationReadError.nonNumeric(key)
        }

        let type = String(cString: number.objCType)
        guard type != "c" && type != "B" else {
            throw DockAnimationReadError.nonNumeric(key)
        }

        let value = number.doubleValue
        guard value.isFinite else {
            throw DockAnimationReadError.nonFinite(key)
        }
        return value
    }
}

@MainActor
final class DockAnimationModel: ObservableObject {
    @Published var revealDelay = DockAnimationValues.initial.revealDelay
    @Published var revealHideDuration = DockAnimationValues.initial.revealHideDuration
    @Published var missionControlDuration = DockAnimationValues.initial.missionControlDuration
    @Published private(set) var lastLiveValues: DockAnimationValues?
    @Published private(set) var statusMessage: String?
    @Published private(set) var statusIsError = false

    init() {
        reloadCurrentValues(publishSuccess: false)
    }

    var currentSummary: String {
        lastLiveValues?.summary ?? "Unavailable"
    }

    var hasDraftChanges: Bool {
        guard let lastLiveValues else { return false }
        return draftValues != lastLiveValues
    }

    var canEdit: Bool {
        lastLiveValues != nil
    }

    var canApply: Bool {
        guard let lastLiveValues else { return false }
        return draftValues.isWithinSupportedRanges && draftValues != lastLiveValues
    }

    func reloadCurrentValues() {
        reloadCurrentValues(publishSuccess: true)
    }

    func apply() {
        guard lastLiveValues != nil else {
            setStatus("Current Dock values are unavailable; reload before applying.", isError: true)
            return
        }

        let draft = draftValues
        guard draft.isFinite else {
            setStatus("Dock animation values must be finite.", isError: true)
            return
        }
        guard draft.isWithinSupportedRanges else {
            setStatus("Dock animation values are outside the supported ranges.", isError: true)
            return
        }
        guard draft != lastLiveValues else {
            setStatus("No Dock animation changes to apply.", isError: false)
            return
        }

        do {
            try Self.writeAndSynchronize(draft)
            try Self.restartDock()
        } catch let error as DockAnimationApplyError {
            setStatus(error.localizedDescription, isError: true)
            return
        } catch {
            setStatus(error.localizedDescription, isError: true)
            return
        }

        lastLiveValues = draft
        setStatus("Applied Dock animation values and restarted Dock.", isError: false)
    }

    private var draftValues: DockAnimationValues {
        DockAnimationValues(revealDelay: revealDelay,
                            revealHideDuration: revealHideDuration,
                            missionControlDuration: missionControlDuration)
    }

    private func reloadCurrentValues(publishSuccess: Bool) {
        lastLiveValues = nil
        let initial = DockAnimationValues.initial
        revealDelay = initial.revealDelay
        revealHideDuration = initial.revealHideDuration
        missionControlDuration = initial.missionControlDuration

        switch DockAnimationPreferences.readLiveValues() {
        case .success(let values):
            lastLiveValues = values
            revealDelay = values.revealDelay
            revealHideDuration = values.revealHideDuration
            missionControlDuration = values.missionControlDuration
            if publishSuccess {
                setStatus("Current Dock values reloaded.", isError: false)
            } else {
                statusMessage = nil
                statusIsError = false
            }
        case .failure(let error):
            setStatus("Unable to read Dock animation values: \(error.localizedDescription)", isError: true)
        }
    }

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }

    private static func writeAndSynchronize(_ values: DockAnimationValues) throws {
        guard let defaults = UserDefaults(suiteName: KineticsConstants.DockAnimation.preferencesDomain) else {
            throw DockAnimationApplyError.preferencesUnavailable
        }

        defaults.set(values.revealDelay, forKey: KineticsConstants.DockAnimation.revealDelayKey)
        defaults.set(values.revealHideDuration, forKey: KineticsConstants.DockAnimation.revealHideDurationKey)
        defaults.set(values.missionControlDuration, forKey: KineticsConstants.DockAnimation.missionControlDurationKey)

        guard defaults.synchronize() else {
            throw DockAnimationApplyError.synchronizationFailed
        }
    }

    private static func restartDock() throws {
        let dockApplications = NSRunningApplication.runningApplications(
            withBundleIdentifier: KineticsConstants.DockAnimation.dockBundleIdentifier
        )
        if let dock = dockApplications.first, dock.terminate() {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw DockAnimationApplyError.restartFailed(error.localizedDescription)
        }

        guard process.terminationStatus == 0 else {
            throw DockAnimationApplyError.restartFailed("/usr/bin/killall Dock exited with status \(process.terminationStatus).")
        }
    }
}
