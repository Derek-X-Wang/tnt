import XCTest
@testable import TNTPlatformMac

/// State-machine contract for the M1 `confirming` state (issue #82).
///
/// Contract (hold-to-confirm, pending decoupled from AppState):
///
/// - In `.confirming`, a hotkey press PRESERVES the pending Rewrite and starts capture.
/// - `.userAffirmed` delivers the pending Rewrite whenever one is set (not only in .confirming).
/// - A new compose/.confirmationProduced while pending overwrites the pending Rewrite.
/// - A confirm-capture turn that produces no tool call discards the pending Rewrite (decline-by-omission).
/// - No double-delivery; decline / error / abandoned paths deliver nothing.
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
        let flow = flowInConfirming(rewrite: "Add rate-limit unit tests.")
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

    // MARK: - In .confirming, hotkey PRESERVES pending Rewrite and starts capture

    func testHotkeyStartListeningDuringConfirmingPreservesPendingRewrite() {
        var flow = flowInConfirming(rewrite: "Pending rewrite text.")
        let directives = flow.handle(.hotkeyStartListening)
        // State transitions to listening (capture starts)
        XCTAssertEqual(flow.state, .listening)
        XCTAssertTrue(directives.contains(.startCapture),
            "Hotkey in .confirming must start capture")
        // Pending Rewrite is PRESERVED (not cleared)
        XCTAssertEqual(flow.pendingRewrite, "Pending rewrite text.",
            "Pending Rewrite must be preserved when user presses hotkey in .confirming")
        // Must not deliver
        XCTAssertFalse(directives.contains(where: {
            if case .deliverRewrite = $0 { return true }
            return false
        }), "Hotkey in .confirming must not deliver the pending Rewrite")
    }

    func testHotkeyStartListeningDuringConfirmingMovesToListening() {
        var flow = flowInConfirming()
        let directives = flow.handle(.hotkeyStartListening)
        XCTAssertEqual(flow.state, .listening)
        XCTAssertTrue(directives.contains(.setState(.listening)))
        XCTAssertTrue(directives.contains(.startCapture))
    }

    // MARK: - .userAffirmed delivers whenever pending Rewrite is set

    func testUserAffirmedDeliversFromConfirmingState() {
        var flow = flowInConfirming(rewrite: "Confirmed text.")
        // Get to the confirm-capture turn and then receive userAffirmed
        // (model calls deliver_prompt → controller maps to .userAffirmed)
        let directives = flow.handle(.userAffirmed)
        XCTAssertTrue(directives.contains(.deliverRewrite("Confirmed text.")),
            ".userAffirmed must emit deliverRewrite when pending Rewrite is set")
        XCTAssertNil(flow.pendingRewrite,
            "pendingRewrite must be cleared after delivery")
    }

    func testUserAffirmedDeliversFromListeningStateIfPendingRewriteSet() {
        // Scenario: user presses hotkey (confirming → listening, preserving pending),
        // speaks affirmation, then flow enters thinking → model calls deliver_prompt
        // → controller fires .userAffirmed while flow is in .thinking state.
        var flow = flowInConfirming(rewrite: "Rewrite that survived the turn.")
        // Press hotkey: confirming → listening (pending preserved)
        _ = flow.handle(.hotkeyStartListening)
        XCTAssertEqual(flow.state, .listening)
        XCTAssertEqual(flow.pendingRewrite, "Rewrite that survived the turn.")
        // Stop listening: → thinking
        _ = flow.handle(.hotkeyStopListening)
        XCTAssertEqual(flow.state, .thinking)
        // Now the model hears affirmation and calls deliver_prompt
        let directives = flow.handle(.userAffirmed)
        XCTAssertTrue(directives.contains(.deliverRewrite("Rewrite that survived the turn.")),
            ".userAffirmed must deliver whenever pending Rewrite is set (not only in .confirming)")
        XCTAssertNil(flow.pendingRewrite)
    }

    func testUserAffirmedDeliversFromSpeakingStateIfPendingRewriteSet() {
        var flow = flowInConfirming(rewrite: "Speaking-state delivery.")
        _ = flow.handle(.hotkeyStartListening)  // → listening (pending preserved)
        _ = flow.handle(.hotkeyStopListening)   // → thinking
        _ = flow.handle(.audioDelta("BBB="))    // → speaking
        XCTAssertEqual(flow.state, .speaking)
        XCTAssertEqual(flow.pendingRewrite, "Speaking-state delivery.")
        let directives = flow.handle(.userAffirmed)
        XCTAssertTrue(directives.contains(.deliverRewrite("Speaking-state delivery.")))
        XCTAssertNil(flow.pendingRewrite)
    }

    func testUserAffirmedWithNoPendingRewriteIsNoOp() {
        var flow = VoiceTurnFlow()
        // No pending Rewrite — userAffirmed should be a no-op (or return minimal directives, no deliverRewrite)
        let directives = flow.handle(.userAffirmed)
        XCTAssertFalse(directives.contains(where: {
            if case .deliverRewrite = $0 { return true }
            return false
        }), ".userAffirmed with no pending Rewrite must not emit deliverRewrite")
    }

    // MARK: - Delivery is exactly once

    func testDeliveryIsExactlyOnce() {
        var flow = flowInConfirming(rewrite: "Deliver once.")
        _ = flow.handle(.userAffirmed)
        // pending is now nil; a second userAffirmed must not deliver
        let directives = flow.handle(.userAffirmed)
        XCTAssertFalse(directives.contains(where: {
            if case .deliverRewrite = $0 { return true }
            return false
        }), "A second .userAffirmed after delivery must not deliver again")
    }

    // MARK: - New compose while pending overwrites

    func testNewConfirmationProducedOverwritesPendingRewrite() {
        var flow = flowInConfirming(rewrite: "Old rewrite.")
        // New confirmationProduced while in confirming → overwrites
        let directives = flow.handle(.confirmationProduced(pendingRewrite: "New rewrite."))
        XCTAssertEqual(flow.pendingRewrite, "New rewrite.",
            "A new confirmationProduced must overwrite the existing pending Rewrite")
        XCTAssertFalse(directives.contains(.deliverRewrite("Old rewrite.")),
            "Overwriting must not deliver the old Rewrite")
    }

    func testNewConfirmationProducedFromThinkingOverwritesPendingRewrite() {
        // Enter confirming, then start a new turn (confirming → listening → thinking)
        // then model produces a new confirmationProduced
        var flow = flowInConfirming(rewrite: "First rewrite.")
        _ = flow.handle(.hotkeyStartListening)  // preserves pending
        _ = flow.handle(.hotkeyStopListening)   // → thinking
        XCTAssertEqual(flow.pendingRewrite, "First rewrite.")
        let directives = flow.handle(.confirmationProduced(pendingRewrite: "Second rewrite."))
        XCTAssertEqual(flow.pendingRewrite, "Second rewrite.")
        XCTAssertFalse(directives.contains(.deliverRewrite("First rewrite.")))
    }

    // MARK: - Confirm-capture turn with no tool call → decline-by-omission

    func testResponseDoneDuringListeningAfterConfirmingDiscardsIfNoPendingDelivery() {
        // After confirming → listening → thinking → responseDone (no deliver_prompt)
        // the pending Rewrite is discarded (decline-by-omission).
        var flow = flowInConfirming(rewrite: "Should be discarded.")
        _ = flow.handle(.hotkeyStartListening)  // → listening (pending preserved)
        _ = flow.handle(.hotkeyStopListening)   // → thinking
        _ = flow.handle(.responseDone)          // confirm turn ends with no tool call → discard
        XCTAssertNil(flow.pendingRewrite,
            "A confirm-capture turn with no tool call must discard the pending Rewrite")
        XCTAssertEqual(flow.state, .idle)
    }

    func testResponseDoneDuringSpeakingAfterConfirmingDiscardsIfNoPendingDelivery() {
        var flow = flowInConfirming(rewrite: "Also discarded.")
        _ = flow.handle(.hotkeyStartListening)  // → listening (pending preserved)
        _ = flow.handle(.hotkeyStopListening)   // → thinking
        _ = flow.handle(.audioDelta("CCC="))    // → speaking
        _ = flow.handle(.responseDone)          // model spoke but no deliver_prompt
        XCTAssertNil(flow.pendingRewrite,
            "Response done after confirm-capture audio (no deliver_prompt) must discard pending")
        XCTAssertEqual(flow.state, .idle)
    }

    // MARK: - Transport / server error → no delivery

    func testTransportErrorDuringConfirmingDoesNotDeliver() {
        var flow = flowInConfirming()
        let directives = flow.handle(.transportError("disconnected"))
        XCTAssertEqual(flow.state, .idle)
        XCTAssertNil(flow.pendingRewrite)
        XCTAssertFalse(directives.contains(where: {
            if case .deliverRewrite = $0 { return true }
            return false
        }), "Transport error must not deliver")
        XCTAssertTrue(directives.contains(where: {
            if case .showError = $0 { return true }
            return false
        }))
    }

    func testTransportErrorWhileListeningWithPendingRewriteDoesNotDeliver() {
        var flow = flowInConfirming(rewrite: "Should not be delivered.")
        _ = flow.handle(.hotkeyStartListening)  // → listening (pending preserved)
        let directives = flow.handle(.transportError("connection lost"))
        XCTAssertNil(flow.pendingRewrite)
        XCTAssertFalse(directives.contains(where: {
            if case .deliverRewrite = $0 { return true }
            return false
        }), "Transport error while listening with pending Rewrite must not deliver")
    }

    func testResponseErrorDuringConfirmingDoesNotDeliver() {
        var flow = flowInConfirming()
        let directives = flow.handle(.responseError("rate limit"))
        XCTAssertEqual(flow.state, .idle)
        XCTAssertNil(flow.pendingRewrite)
        XCTAssertFalse(directives.contains(where: {
            if case .deliverRewrite = $0 { return true }
            return false
        }), "Response error must not deliver")
    }

    // MARK: - userDeclined still clears (for explicit decline path)

    func testUserDeclinedClearsPendingRewriteWithoutDelivering() {
        var flow = flowInConfirming(rewrite: "Declined rewrite.")
        let directives = flow.handle(.userDeclined)
        XCTAssertEqual(flow.state, .idle)
        XCTAssertNil(flow.pendingRewrite)
        XCTAssertFalse(directives.contains(where: {
            if case .deliverRewrite = $0 { return true }
            return false
        }), "Decline must not emit deliverRewrite")
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
