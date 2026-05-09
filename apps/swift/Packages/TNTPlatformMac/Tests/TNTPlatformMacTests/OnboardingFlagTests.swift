import XCTest
@testable import TNTPlatformMac

/// Round-trip and key-stability tests for the `tnt.has_onboarded` flag.
final class OnboardingFlagTests: XCTestCase {

    func testKeyMatchesAcceptanceCriterionVerbatim() {
        // The M0/S4 issue body specifies the UserDefaults flag key
        // verbatim as `tnt.has_onboarded`; drift here breaks the
        // documented contract.
        XCTAssertEqual(OnboardingFlag.userDefaultsKey, "tnt.has_onboarded")
    }

    func testDefaultIsFalseWhenUnset() {
        let suite = UserDefaults(suiteName: "TNTOnboardingTestSuite-\(UUID().uuidString)")!
        XCTAssertFalse(OnboardingFlag.hasOnboarded(in: suite))
    }

    func testRoundTripsTrue() {
        let suite = UserDefaults(suiteName: "TNTOnboardingTestSuite-\(UUID().uuidString)")!
        OnboardingFlag.setOnboarded(true, in: suite)
        XCTAssertTrue(OnboardingFlag.hasOnboarded(in: suite))
    }

    func testRoundTripsFalse() {
        let suite = UserDefaults(suiteName: "TNTOnboardingTestSuite-\(UUID().uuidString)")!
        OnboardingFlag.setOnboarded(true, in: suite)
        OnboardingFlag.setOnboarded(false, in: suite)
        XCTAssertFalse(OnboardingFlag.hasOnboarded(in: suite))
    }
}
