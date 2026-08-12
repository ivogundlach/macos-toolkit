import CoreFoundation
import XCTest
@testable import Kinetics

final class DockAnimationPreferencesTests: XCTestCase {
    func testCreatesAllMissingValues() throws {
        let domain = temporaryDomain()
        defer { clear(domain) }

        guard case .success(true) = DockAnimationPreferences.initializeMissingValues(in: domain) else {
            return XCTFail("Expected missing values to be initialized")
        }

        XCTAssertEqual(value(for: KineticsConstants.DockAnimation.revealDelayKey, in: domain), 0.0)
        XCTAssertEqual(value(for: KineticsConstants.DockAnimation.revealHideDurationKey, in: domain), 0.5)
        XCTAssertEqual(value(for: KineticsConstants.DockAnimation.missionControlDurationKey, in: domain), 0.05)
        guard case .success(false) = DockAnimationPreferences.initializeMissingValues(in: domain) else {
            return XCTFail("Expected a second initialization to make no changes")
        }
    }

    func testPreservesExistingValuesWhileCreatingOnlyMissingValues() throws {
        let domain = temporaryDomain()
        defer { clear(domain) }
        set(0.4, for: KineticsConstants.DockAnimation.revealDelayKey, in: domain)
        set(0.8, for: KineticsConstants.DockAnimation.revealHideDurationKey, in: domain)
        XCTAssertTrue(CFPreferencesSynchronize(domain as CFString,
                                               kCFPreferencesCurrentUser,
                                               kCFPreferencesAnyHost))

        guard case .success(true) = DockAnimationPreferences.initializeMissingValues(in: domain) else {
            return XCTFail("Expected the one missing value to be initialized")
        }

        XCTAssertEqual(value(for: KineticsConstants.DockAnimation.revealDelayKey, in: domain), 0.4)
        XCTAssertEqual(value(for: KineticsConstants.DockAnimation.revealHideDurationKey, in: domain), 0.8)
        XCTAssertEqual(value(for: KineticsConstants.DockAnimation.missionControlDurationKey, in: domain), 0.05)
    }

    private func temporaryDomain() -> String {
        "com.ivogundlach.KineticsTests.\(UUID().uuidString)"
    }

    private func value(for key: String, in domain: String) -> Double? {
        (CFPreferencesCopyValue(key as CFString,
                                domain as CFString,
                                kCFPreferencesCurrentUser,
                                kCFPreferencesAnyHost) as? NSNumber)?.doubleValue
    }

    private func set(_ value: Double, for key: String, in domain: String) {
        CFPreferencesSetValue(key as CFString,
                              value as CFNumber,
                              domain as CFString,
                              kCFPreferencesCurrentUser,
                              kCFPreferencesAnyHost)
    }

    private func clear(_ domain: String) {
        for key in [KineticsConstants.DockAnimation.revealDelayKey,
                    KineticsConstants.DockAnimation.revealHideDurationKey,
                    KineticsConstants.DockAnimation.missionControlDurationKey] {
            CFPreferencesSetValue(key as CFString,
                                  nil,
                                  domain as CFString,
                                  kCFPreferencesCurrentUser,
                                  kCFPreferencesAnyHost)
        }
        CFPreferencesSynchronize(domain as CFString,
                                 kCFPreferencesCurrentUser,
                                 kCFPreferencesAnyHost)
    }
}
