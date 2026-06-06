import XCTest
@testable import TNTPlatformMac

/// Tests for the launch mic pre-warm preference (issue #73). The
/// default-ON-when-unset behavior is the load-bearing bit: a fresh install
/// must pre-warm without the user setting anything.
final class PrewarmSettingTests: XCTestCase {

    func testKeyIsStable() {
        XCTAssertEqual(PrewarmSetting.userDefaultsKey, "tnt.prewarm_mic")
    }

    func testDefaultsOnWhenUnset() {
        let suite = UserDefaults(suiteName: "TNTPrewarmTestSuite-\(UUID().uuidString)")!
        // Unset → enabled (default-on), so a fresh install warms the mic.
        XCTAssertTrue(PrewarmSetting.isEnabled(in: suite))
    }

    func testRespectsExplicitDisable() {
        let suite = UserDefaults(suiteName: "TNTPrewarmTestSuite-\(UUID().uuidString)")!
        PrewarmSetting.setEnabled(false, in: suite)
        XCTAssertFalse(PrewarmSetting.isEnabled(in: suite))
    }

    func testRespectsExplicitEnable() {
        let suite = UserDefaults(suiteName: "TNTPrewarmTestSuite-\(UUID().uuidString)")!
        PrewarmSetting.setEnabled(false, in: suite)
        PrewarmSetting.setEnabled(true, in: suite)
        XCTAssertTrue(PrewarmSetting.isEnabled(in: suite))
    }
}
