import XCTest
@testable import TNTPlatformMac

/// State-machine contract for the M1 `confirming` state (issue #46).
///
/// Acceptance criteria:
/// - Entering confirmation stores the pending Rewrite; affirm emits
///   exactly one deliverRewrite directive and clears it.
/// - Decline clears without delivering.
/// - New Voice Turn while confirming supersedes/clears the pending Rewrite.
/// - Interruption or transport error during confirming does not deliver.
/// - A second affirm for an already-delivered Rewrite is a no-op.
final class VoiceTurnFlowConfirmingTests: XCTestCase {

    // MARK: - Helper: drive to confirming state

    private func flowInConfirming(rewrite: String = "Add a unit test.") -> VoiceTurnFlow {
        var flow = VoiceTurnFlow()
        // Drive to speaking.
        _ = flow.handle(.hotkeyStartListening)
        _ = flow.handle(.hotkeyStopListening)
        _ = flow.handle(.audioDelta("AAA="))
        XCTAssertEqual(flow.state, .speaking)
        // Model produces confirmation while speaking.
        let directives = flow.handle(.confirmationProduced(pendingRewrite: rewrite))
        XCTAssertEqual(flow.state, .confirming)
        XCTAssertEqual(directives, [.setState(.confirming)])
        XCTAssertEqual(flow.pendingRewrite, rewrite)
        return flow
    }

    // MARK: - Entering confirmation stores the pending Rewrite

    func testConfirmationProducedFromSpeakingStoresPendingRewrite() {
        var flow = flowInConfirming(rewrite: "Add rate-limit unit tests.")
        XCTAssertEqual(flow.state, .confirming)
        XCTAssertEqual(flow.pendingRewrite, "Add rate-limit unit tests.")
    }

    func testConfirmationProducedFromThinkingAlsoEntersConfirming() {
        var flow = VoiceTurnFlow()
        _ = flow.handle(.hotkeyStartListening)
        _ = flow.handle(.hotkeyStopListening)
        XCTAssertEqual(flow.state, .thinking)
        let directives = flow.handle(.confirmationProduced(pendingRewrite: "Prompt text."))
        XCTAssertEqual(flow.state, .confirming)
        XCTAssertEqual(directives, [.setState(.confirming)])
        XCTAssertEqual(flow.pendingRewrite, "Prompt text.")
    }

    // MARK: - Affirm → exactly-once deliverRewrite + idle

    func testUserAffirmedDeliversRewriteAndMovesToIdle() {
        var flow = flowInConfirming(rewrite: "Add a unit test.")
        let directives = flow.handle(.userAffirmed)
        XCTAssertEqual(flow.state, .idle)
        XCTAssertNil(flow.pendingRewrite, "pendingRewrite must be cleared after affirm")
        XCTAssertEqual(directives, [
            .deliverRewrite("Add a unit test."),
            .setState(.idle),
        ])
    }

    func testDeliveryIsExactlyOnce() {
        var flow = flowInConfirming()
        _ = flow.handle(.userAffirmed)
        // State is now idle; a second userAffirmed is a no-op (not confirming).
        let directives = flow.handle(.userAffirmed)
        XCTAssertEqual(directives, [],
            "A second userAffirmed in a non-confirming state must be a no-op — delivery is exactly-once")
    }

    // MARK: - Decline → no deliverRewrite

    func testUserDeclinedClearsPendingRewriteWithoutDelivering() {
        var flow = flowInConfirming(rewrite: "Add a unit test.")
        let directives = flow.handle(.userDeclined)
        XCTAssertEqual(flow.state, .idle)
        XCTAssertNil(flow.pendingRewrite)
        XCTAssertEqual(directives, [.setState(.idle)])
        // Critically: no deliverRewrite.
        XCTAssertFalse(directives.contains(where: {
            if case .deliverRewrite = $0 { return true }
            return false
        }), "Decline must not emit deliverRewrite")
    }

    // MARK: - New Voice Turn supersedes

    func testNewVoiceTurnDuringConfirmingClearsPendingWithoutDelivering() {
        var flow = flowInConfirming(rewrite: "Stale prompt.")
        let directives = flow.handle(.hotkeyStartListening)
        XCTAssertEqual(flow.state, .listening)
        XCTAssertNil(flow.pendingRewrite,
            "Starting a new Voice Turn during confirming must clear the pending Rewrite")
        XCTAssertFalse(directives.contains(where: {
            if case .deliverRewrite = $0 { return true }
            return false
        }), "Starting a new turn must not deliver the stale pending Rewrite")
        XCTAssertTrue(directives.contains(.startCapture))
    }

    // MARK: - Transport error during confirming → no delivery

    func testTransportErrorDuringConfirmingDoesNotDeliver() {
        var flow = flowInConfirming()
        let directives = flow.handle(.transportError("disconnected"))
        XCTAssertEqual(flow.state, .idle)
        XCTAssertNil(flow.pendingRewrite)
        XCTAssertFalse(directives.contains(where: {
            if case .deliverRewrite = $0 { return true }
            return false
        }), "Transport error during confirmation must not deliver")
        XCTAssertTrue(directives.contains(where: {
            if case .showError = $0 { return true }
            return false
        }))
    }

    func testResponseErrorDuringConfirmingDoesNotDeliver() {
        var flow = flowInConfirming()
        let directives = flow.handle(.responseError("rate limit"))
        XCTAssertEqual(flow.state, .idle)
        XCTAssertNil(flow.pendingRewrite)
        XCTAssertFalse(directives.contains(where: {
            if case .deliverRewrite = $0 { return true }
            return false
        }), "Response error during confirmation must not deliver")
    }

    // MARK: - AppState confirming mappings

    func testConfirmingStateHasSymbolAndMenuTitle() {
        XCTAssertFalse(AppState.confirming.symbolName.isEmpty)
        XCTAssertTrue(AppState.confirming.menuTitle.hasPrefix("TNT — "))
    }

    // MARK: - Existing M0 tests still pass (regression guard)

    func testCleanTurnStillWorks() {
        var flow = VoiceTurnFlow()
        XCTAssertEqual(flow.handle(.hotkeyStartListening), [.setState(.listening), .startCapture])
        XCTAssertEqual(flow.handle(.hotkeyStopListening), [.stopCapture, .sendCommitAndCreate, .setState(.thinking)])
        XCTAssertEqual(flow.handle(.audioDelta("AAA=")), [.setState(.speaking), .enqueuePlayback("AAA=")])
        XCTAssertEqual(flow.handle(.responseDone), [.setState(.idle)])
    }
}
