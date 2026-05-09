import XCTest
@testable import TNTPlatformMac

/// Hold-vs-tap state machine for the global hotkey.
///
/// Per the M0/S3 acceptance criteria the recognizer must distinguish:
///   * Tap = `keyDown` → `keyUp` within 250ms (toggle latch on/off)
///   * Hold = `keyDown` → `keyUp` ≥ 250ms apart (snap back to .idle)
/// and must be robust to reentrant `keyDown` events (auto-repeat) and
/// orphan `keyUp` events.
final class HotkeyGestureRecognizerTests: XCTestCase {

    // MARK: - Tap path

    func testFirstTapAtJustUnderThresholdLatchesListeningOn() {
        var r = HotkeyGestureRecognizer()
        XCTAssertEqual(r.keyDown(at: 0.0), .startListening)
        XCTAssertTrue(r.isListening)

        // 240ms — just under the 250ms threshold → tap.
        XCTAssertEqual(r.keyUp(at: 0.240), .noChange)
        XCTAssertTrue(r.isListening, "After a tap, the lamp must stay listening (latched).")
        XCTAssertTrue(r.tapToggled, "Tap latch must be set after a tap-on.")
    }

    func testSecondTapAtJustUnderThresholdReleasesListening() {
        var r = HotkeyGestureRecognizer()
        _ = r.keyDown(at: 0.0)
        _ = r.keyUp(at: 0.240)               // tap → latched on

        _ = r.keyDown(at: 1.0)
        XCTAssertEqual(r.keyUp(at: 1.240), .stopListening, "Second tap must release the latch.")
        XCTAssertFalse(r.isListening)
        XCTAssertFalse(r.tapToggled)
    }

    // MARK: - Hold path

    func testHoldAtJustOverThresholdSnapsBackToIdle() {
        var r = HotkeyGestureRecognizer()
        XCTAssertEqual(r.keyDown(at: 0.0), .startListening)

        // 260ms — just over the threshold → hold.
        XCTAssertEqual(r.keyUp(at: 0.260), .stopListening)
        XCTAssertFalse(r.isListening, "Releasing a hold must return the lamp to .idle.")
        XCTAssertFalse(r.tapToggled)
    }

    func testHoldCancelsAnExistingTapLatch() {
        var r = HotkeyGestureRecognizer()
        _ = r.keyDown(at: 0.0)
        _ = r.keyUp(at: 0.10)                // tap → latched on

        _ = r.keyDown(at: 1.0)
        XCTAssertEqual(r.keyUp(at: 1.30), .stopListening, "Holding while latched-on must release the latch.")
        XCTAssertFalse(r.tapToggled)
    }

    // MARK: - Reentrancy / auto-repeat

    func testZeroMillisecondRepeatedKeyDownsAreIgnored() {
        var r = HotkeyGestureRecognizer()
        XCTAssertEqual(r.keyDown(at: 0.0), .startListening)
        XCTAssertEqual(r.keyDown(at: 0.0), .noChange, "Repeat keyDown at the same instant must collapse.")
        XCTAssertEqual(r.keyDown(at: 0.05), .noChange, "Reentrant keyDown without a keyUp must collapse.")

        // Final keyUp at 240ms still measured against the FIRST keyDown at t=0.
        XCTAssertEqual(r.keyUp(at: 0.240), .noChange)
        XCTAssertTrue(r.isListening, "Auto-repeat ⌥Space must register as a single tap, not many.")
    }

    func testKeyUpWithoutKeyDownIsNoOp() {
        var r = HotkeyGestureRecognizer()
        XCTAssertEqual(r.keyUp(at: 1.0), .noChange)
        XCTAssertFalse(r.isListening)
        XCTAssertFalse(r.tapToggled)
    }

    // MARK: - External cancel

    func testCancelClearsLatchAndStopsListening() {
        var r = HotkeyGestureRecognizer()
        _ = r.keyDown(at: 0.0)
        _ = r.keyUp(at: 0.10)                // latched on

        XCTAssertEqual(r.cancel(), .stopListening)
        XCTAssertFalse(r.isListening)
        XCTAssertFalse(r.tapToggled)
    }

    func testCancelWhenIdleIsNoOp() {
        var r = HotkeyGestureRecognizer()
        XCTAssertEqual(r.cancel(), .noChange)
    }

    // MARK: - Configuration

    func testConfigurableHoldThreshold() {
        var r = HotkeyGestureRecognizer(configuration: .init(holdThreshold: 0.5))
        _ = r.keyDown(at: 0.0)
        // 300ms is now a tap (under 500ms threshold).
        XCTAssertEqual(r.keyUp(at: 0.300), .noChange)
        XCTAssertTrue(r.isListening, "Tap latch must apply when keyUp is below the configured threshold.")
    }
}
