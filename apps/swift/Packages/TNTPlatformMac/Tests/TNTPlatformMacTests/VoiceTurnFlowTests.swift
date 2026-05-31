import XCTest
@testable import TNTPlatformMac

/// Pure state-machine contract for one Voice Turn (per CONTEXT.md:
/// "one round of human speech → TNT spoken reply"). The fixtures
/// below are the M0/S8 acceptance scenarios — clean turn, interrupted
/// turn, transport-failure turn — replayed against `VoiceTurnFlow`.
final class VoiceTurnFlowTests: XCTestCase {

    // MARK: - Clean turn

    func testCleanTurnDrivesIdleListeningThinkingSpeakingIdle() {
        var flow = VoiceTurnFlow()

        // Hold ⌥Space → start listening + start mic capture.
        XCTAssertEqual(flow.handle(.hotkeyStartListening), [
            .setState(.listening),
            .startCapture,
        ])
        XCTAssertEqual(flow.state, .listening)

        // Release → commit + ask for response → thinking.
        XCTAssertEqual(flow.handle(.hotkeyStopListening), [
            .stopCapture,
            .sendCommitAndCreate,
            .setState(.thinking),
        ])
        XCTAssertEqual(flow.state, .thinking)

        // First audio delta arrives → flip to speaking + enqueue.
        XCTAssertEqual(flow.handle(.audioDelta("AAA=")), [
            .setState(.speaking),
            .enqueuePlayback("AAA="),
        ])
        XCTAssertEqual(flow.state, .speaking)

        // Subsequent deltas just enqueue.
        XCTAssertEqual(flow.handle(.audioDelta("BBB=")), [
            .enqueuePlayback("BBB="),
        ])
        XCTAssertEqual(flow.state, .speaking)

        // response.done → idle.
        XCTAssertEqual(flow.handle(.responseDone), [
            .setState(.idle),
        ])
        XCTAssertEqual(flow.state, .idle)
    }

    // MARK: - Interrupted turn

    func testInterruptDuringSpeakingCancelsAndStartsNewListening() {
        var flow = VoiceTurnFlow()

        // Drive into .speaking via a normal turn.
        _ = flow.handle(.hotkeyStartListening)
        _ = flow.handle(.hotkeyStopListening)
        _ = flow.handle(.audioDelta("AAA="))
        XCTAssertEqual(flow.state, .speaking)

        // Hold during speaking → cancel + clear + restart player + start mic.
        let directives = flow.handle(.hotkeyStartListening)
        XCTAssertEqual(directives, [
            .sendCancelAndClear,
            .stopPlayer,
            .restartPlayer,
            .setState(.listening),
            .startCapture,
        ])
        XCTAssertEqual(flow.state, .listening)
    }

    // MARK: - Transport failure mid-turn

    func testTransportErrorDuringThinkingReturnsToIdleWithBanner() {
        var flow = VoiceTurnFlow()

        _ = flow.handle(.hotkeyStartListening)
        _ = flow.handle(.hotkeyStopListening)
        XCTAssertEqual(flow.state, .thinking)

        let directives = flow.handle(.transportError("network dropped"))
        XCTAssertEqual(directives, [
            .showError("network dropped"),
            .stopCapture,
            .stopPlayer,
            .restartPlayer,
            .setState(.idle),
        ])
        XCTAssertEqual(flow.state, .idle)

        // Next press starts a fresh turn cleanly.
        XCTAssertEqual(flow.handle(.hotkeyStartListening), [
            .setState(.listening),
            .startCapture,
        ])
    }

    func testResponseErrorMidTurnReturnsToIdleWithBanner() {
        var flow = VoiceTurnFlow()
        _ = flow.handle(.hotkeyStartListening)
        _ = flow.handle(.hotkeyStopListening)

        let directives = flow.handle(.responseError("rate limit hit"))
        XCTAssertEqual(directives, [
            .showError("rate limit hit"),
            .stopCapture,
            .stopPlayer,
            .restartPlayer,
            .setState(.idle),
        ])
    }

    // MARK: - Tap-toggle drives the same lifecycle

    func testTapToggleFlowMatchesHoldRelease() {
        // Tap toggle drives the same `hotkeyStartListening` /
        // `hotkeyStopListening` events as hold-release — the
        // recogniser collapses both into the same edges. Verify the
        // flow's state transitions are identical to the clean-turn
        // path above.
        var flow = VoiceTurnFlow()
        _ = flow.handle(.hotkeyStartListening)
        _ = flow.handle(.hotkeyStopListening)
        _ = flow.handle(.audioDelta("AAA="))
        _ = flow.handle(.responseDone)
        XCTAssertEqual(flow.state, .idle)
    }

    // MARK: - Spurious events do not crash

    func testSpuriousDoneInIdleIsNoOp() {
        var flow = VoiceTurnFlow()
        let directives = flow.handle(.responseDone)
        XCTAssertEqual(directives, [])
        XCTAssertEqual(flow.state, .idle)
    }

    func testSpuriousAudioDeltaInIdleIsNoOp() {
        var flow = VoiceTurnFlow()
        let directives = flow.handle(.audioDelta("AAA="))
        XCTAssertEqual(directives, [])
        XCTAssertEqual(flow.state, .idle)
    }

    // MARK: - Issue #68: .thinking barge-in sends cancel/clear

    /// When the user presses the hotkey while TNT is in .thinking
    /// (waiting for the first audio delta), the in-flight response must
    /// be cancelled before starting the new capture. Without this fix,
    /// the old response stays active and can collide with the new
    /// response.create — stranding state and producing two simultaneous
    /// responses in the same session buffer.
    ///
    /// The .thinking interrupt is lighter than the .speaking interrupt:
    /// no `stopPlayer`/`restartPlayer` because nothing is playing yet.
    func testThinkingBargeInCancelsBeforeStartingCapture() {
        var flow = VoiceTurnFlow()

        // Drive into .thinking.
        _ = flow.handle(.hotkeyStartListening)
        _ = flow.handle(.hotkeyStopListening)
        XCTAssertEqual(flow.state, .thinking)

        // Barge in from .thinking: must cancel + clear before starting new capture.
        let directives = flow.handle(.hotkeyStartListening)
        XCTAssertEqual(directives, [
            .sendCancelAndClear,     // cancel the in-flight response
            .setState(.listening),   // update UI
            .startCapture,           // begin new mic capture
        ])
        XCTAssertEqual(flow.state, .listening)
    }

    /// The .thinking barge-in directive list must include cancel/clear BEFORE
    /// startCapture — not double-deliver or swap the ordering.
    func testThinkingBargeInDirectiveOrdering() {
        var flow = VoiceTurnFlow()
        _ = flow.handle(.hotkeyStartListening)
        _ = flow.handle(.hotkeyStopListening)

        let directives = flow.handle(.hotkeyStartListening)

        // cancel/clear must come first; startCapture must come last.
        XCTAssertEqual(directives.first, .sendCancelAndClear,
            "sendCancelAndClear must be first in .thinking barge-in directives")
        XCTAssertEqual(directives.last, .startCapture,
            "startCapture must be last in .thinking barge-in directives")
    }

    /// A .speaking interrupt must still emit stopPlayer + restartPlayer
    /// (unchanged by the .thinking fix).
    func testSpeakingInterruptStillEmitsPlaybackFlush() {
        var flow = VoiceTurnFlow()
        _ = flow.handle(.hotkeyStartListening)
        _ = flow.handle(.hotkeyStopListening)
        _ = flow.handle(.audioDelta("AAA="))

        let directives = flow.handle(.hotkeyStartListening)
        XCTAssertTrue(directives.contains(.stopPlayer),
            ".speaking interrupt must still flush the player")
        XCTAssertTrue(directives.contains(.restartPlayer),
            ".speaking interrupt must still restart the player")
    }

    /// A clean Voice Turn starting from .idle must NOT emit cancel/clear
    /// (unchanged — no in-flight response to cancel from idle).
    func testIdleStartDoesNotCancelAndClear() {
        var flow = VoiceTurnFlow()
        let directives = flow.handle(.hotkeyStartListening)
        XCTAssertFalse(directives.contains(.sendCancelAndClear),
            "Starting from .idle must not cancel an in-flight response")
        XCTAssertEqual(flow.state, .listening)
    }
}
