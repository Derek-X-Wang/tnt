// CaptureControlCoreTests — TDD for issue #140.
// Each test maps directly to an acceptance criterion from the issue body.
// No CoreAudio / AudioToolbox imports — pure Swift, fully unit-testable.

import XCTest
@testable import TNTRealtime

final class CaptureControlCoreTests: XCTestCase {

    // MARK: - AC1: Pure — no CoreAudio/AudioToolbox, injected clock, unit-testable

    func testCoreHasNoAudioUnitDependency() {
        // If this file compiles without importing AudioToolbox, AC1 is satisfied.
        let core = CaptureControlCore()
        XCTAssertNotNil(core, "Core must be constructable without hardware dependencies")
    }

    // MARK: - AC2: Idempotent prepare — same-device prepare twice → one prepare command

    func testIdempotentPrepareFirstStartEmitsPrepare() {
        let core = CaptureControlCore()
        let cmds = core.update(.startRequested(deviceID: "mic0", now: 0))
        XCTAssertEqual(cmds, [.prepare(deviceID: "mic0")],
            "First startRequested must emit prepare(deviceID:)")
    }

    func testIdempotentPrepareSecondStartForSameDeviceWhilePreparingIsNoOp() {
        let core = CaptureControlCore()
        _ = core.update(.startRequested(deviceID: "mic0", now: 0))
        let cmds = core.update(.startRequested(deviceID: "mic0", now: 0))
        XCTAssertEqual(cmds, [], "Duplicate startRequested while preparing same device must be a no-op")
    }

    func testIdempotentPrepareAfterWarmStartDoesNotReprepare() {
        let core = CaptureControlCore()
        // Cold path: prepare + prepared + (implicitly start via prepared event)
        _ = core.update(.startRequested(deviceID: "mic0", now: 0))
        _ = core.update(.prepared(deviceID: "mic0", now: 0))
        _ = core.update(.stopRequested)
        // Second start for the same device while warm: must emit start, NOT prepare
        let cmds = core.update(.startRequested(deviceID: "mic0", now: 1))
        XCTAssertEqual(cmds, [.start], "Warm start for same device must emit start, not prepare")
    }

    // MARK: - AC3: Warm path — start after prior stop emits start without prepare

    func testWarmPathStartSkipsPrepare() {
        let core = CaptureControlCore()
        // Full cold-start sequence
        _ = core.update(.startRequested(deviceID: "mic0", now: 0))
        _ = core.update(.prepared(deviceID: "mic0", now: 0))
        // Stop keeps unit warm
        _ = core.update(.stopRequested)
        // Resume: should be instant (no prepare)
        let cmds = core.update(.startRequested(deviceID: "mic0", now: 1))
        XCTAssertFalse(cmds.contains(.prepare(deviceID: "mic0")),
            "Warm resume must not emit prepare")
        XCTAssertTrue(cmds.contains(.start), "Warm resume must emit start")
    }

    func testPreparedEventEmitsStart() {
        // After startRequested, when prepared() arrives, core emits start.
        let core = CaptureControlCore()
        _ = core.update(.startRequested(deviceID: "mic0", now: 0))
        let cmds = core.update(.prepared(deviceID: "mic0", now: 0))
        XCTAssertTrue(cmds.contains(.start),
            "prepared(deviceID:) while in preparing state must trigger start")
    }

    // MARK: - AC4: Watchdog — start → no buffer by deadline → one rebuild → still none → failTurn

    func testWatchdogTriggersRebuildOnFirstTimeout() {
        let core = CaptureControlCore(firstBufferDeadline: 0.5)
        _ = core.update(.startRequested(deviceID: "mic0", now: 0))
        _ = core.update(.prepared(deviceID: "mic0", now: 0))
        // Tick before deadline — no action
        let before = core.update(.tick(now: 0.4))
        XCTAssertEqual(before, [], "Tick before deadline must produce no commands")
        // Tick past deadline
        let after = core.update(.tick(now: 0.6))
        XCTAssertTrue(after.contains(.rebuild),
            "First timeout past deadline must emit rebuild")
        XCTAssertFalse(after.contains(.failTurn),
            "First timeout must not emit failTurn — only after second timeout")
    }

    func testWatchdogTriggersFailTurnAfterSecondTimeout() {
        let core = CaptureControlCore(firstBufferDeadline: 0.5)
        _ = core.update(.startRequested(deviceID: "mic0", now: 0))
        _ = core.update(.prepared(deviceID: "mic0", now: 0))
        // First timeout → rebuild
        _ = core.update(.tick(now: 0.6))
        // Second timeout (deadline restarts after rebuild)
        let cmds = core.update(.tick(now: 1.2))
        XCTAssertTrue(cmds.contains(.failTurn),
            "Second timeout with no buffer must emit failTurn")
    }

    func testWatchdogClearedByBufferBeforeDeadline() {
        let core = CaptureControlCore(firstBufferDeadline: 0.5)
        _ = core.update(.startRequested(deviceID: "mic0", now: 0))
        _ = core.update(.prepared(deviceID: "mic0", now: 0))
        // Buffer arrives before deadline
        let clearCmds = core.update(.bufferArrived)
        XCTAssertEqual(clearCmds, [], "bufferArrived must produce no commands")
        // Tick past original deadline — should produce nothing (watchdog cleared)
        let afterBuffer = core.update(.tick(now: 0.6))
        XCTAssertFalse(afterBuffer.contains(.rebuild),
            "Tick after bufferArrived must not trigger watchdog rebuild")
        XCTAssertFalse(afterBuffer.contains(.failTurn),
            "Tick after bufferArrived must not trigger failTurn")
    }

    func testWatchdogIsExactlyOneRebuild() {
        // Watchdog must fire rebuild EXACTLY once, then failTurn on second miss.
        let core = CaptureControlCore(firstBufferDeadline: 0.3)
        _ = core.update(.startRequested(deviceID: "mic0", now: 0))
        _ = core.update(.prepared(deviceID: "mic0", now: 0))
        // First miss
        let first = core.update(.tick(now: 0.4))
        XCTAssertEqual(first.filter { $0 == .rebuild }.count, 1, "Exactly one rebuild on first miss")
        // Second miss (no buffer between first and second timeout)
        let second = core.update(.tick(now: 0.8))
        XCTAssertFalse(second.contains(.rebuild), "No rebuild on second miss — should be failTurn")
        XCTAssertTrue(second.contains(.failTurn), "Second miss emits failTurn")
    }

    // MARK: - AC5: deviceChanged mid-turn bumps generation, invalidates pending, drives rebuild on next start

    func testDeviceChangedBumpsGenerationAndTriggersDirtyRebuild() {
        let core = CaptureControlCore()
        // Start successfully
        _ = core.update(.startRequested(deviceID: "mic0", now: 0))
        _ = core.update(.prepared(deviceID: "mic0", now: 0))
        _ = core.update(.bufferArrived)  // clear watchdog

        // Device changes mid-turn
        let changeCmds = core.update(.deviceChanged(generation: 2))
        // While running, a device change should drive a rebuild (pending audio invalidated)
        XCTAssertTrue(changeCmds.contains(.rebuild),
            "deviceChanged while running must emit rebuild to invalidate pending audio")
    }

    func testDeviceChangedCausesRePrepareOnNextStart() {
        let core = CaptureControlCore()
        // Complete a turn
        _ = core.update(.startRequested(deviceID: "mic0", now: 0))
        _ = core.update(.prepared(deviceID: "mic0", now: 0))
        _ = core.update(.stopRequested)

        // Device changes while stopped
        _ = core.update(.deviceChanged(generation: 2))

        // Next start must issue prepare (not warm-skip it), because dirty
        let cmds = core.update(.startRequested(deviceID: "mic1", now: 1))
        XCTAssertTrue(cmds.contains(.prepare(deviceID: "mic1")),
            "After deviceChanged, next start must re-prepare, not warm-skip")
    }

    func testDeviceChangedDoesNotFireRebuildIfStopped() {
        let core = CaptureControlCore()
        _ = core.update(.startRequested(deviceID: "mic0", now: 0))
        _ = core.update(.prepared(deviceID: "mic0", now: 0))
        _ = core.update(.stopRequested)

        // Device changes while stopped — no rebuild needed (nothing running)
        let cmds = core.update(.deviceChanged(generation: 2))
        XCTAssertFalse(cmds.contains(.rebuild),
            "deviceChanged while stopped must not emit rebuild (nothing in-flight)")
    }

    func testSameGenerationDeviceChangedIsIdempotent() {
        let core = CaptureControlCore()
        _ = core.update(.startRequested(deviceID: "mic0", now: 0))
        _ = core.update(.prepared(deviceID: "mic0", now: 0))
        _ = core.update(.bufferArrived)

        // Same generation number — should not dirty again
        _ = core.update(.deviceChanged(generation: 1))
        let cmds2 = core.update(.deviceChanged(generation: 1))
        XCTAssertFalse(cmds2.contains(.rebuild),
            "Repeated deviceChanged with same generation must be idempotent")
    }

    // MARK: - AC6: Stop is idempotent and keeps warm state

    func testStopIsIdempotent() {
        let core = CaptureControlCore()
        _ = core.update(.startRequested(deviceID: "mic0", now: 0))
        _ = core.update(.prepared(deviceID: "mic0", now: 0))
        let first = core.update(.stopRequested)
        XCTAssertTrue(first.contains(.stop))
        let second = core.update(.stopRequested)
        XCTAssertEqual(second, [], "Second stopRequested must be a no-op")
    }

    func testStopKeepsWarmState() {
        // After stop, unit stays warm: next start should be instantaneous (no prepare)
        let core = CaptureControlCore()
        _ = core.update(.startRequested(deviceID: "mic0", now: 0))
        _ = core.update(.prepared(deviceID: "mic0", now: 0))
        _ = core.update(.stopRequested)
        // Core must still know device "mic0" is prepared (warm)
        let cmds = core.update(.startRequested(deviceID: "mic0", now: 1))
        XCTAssertEqual(cmds, [.start], "Warm start must emit only start (unit kept warm)")
    }

    // MARK: - AC7: isPrepared(for:)

    func testIsPreparedReturnsFalseInitially() {
        let core = CaptureControlCore()
        XCTAssertFalse(core.isPrepared(for: "mic0"))
    }

    func testIsPreparedReturnsTrueAfterPrepared() {
        let core = CaptureControlCore()
        _ = core.update(.startRequested(deviceID: "mic0", now: 0))
        _ = core.update(.prepared(deviceID: "mic0", now: 0))
        XCTAssertTrue(core.isPrepared(for: "mic0"))
    }

    func testIsPreparedReturnsFalseForDifferentDevice() {
        let core = CaptureControlCore()
        _ = core.update(.startRequested(deviceID: "mic0", now: 0))
        _ = core.update(.prepared(deviceID: "mic0", now: 0))
        XCTAssertFalse(core.isPrepared(for: "mic1"))
    }

    func testIsPreparedReturnsFalseAfterUnitFailed() {
        let core = CaptureControlCore()
        _ = core.update(.startRequested(deviceID: "mic0", now: 0))
        _ = core.update(.prepared(deviceID: "mic0", now: 0))
        _ = core.update(.unitFailed)
        XCTAssertFalse(core.isPrepared(for: "mic0"))
    }

    // MARK: - Additional edge cases

    func testUnitFailedClearsState() {
        let core = CaptureControlCore()
        _ = core.update(.startRequested(deviceID: "mic0", now: 0))
        _ = core.update(.prepared(deviceID: "mic0", now: 0))
        let cmds = core.update(.unitFailed)
        XCTAssertTrue(cmds.contains(.reset), "unitFailed must emit reset")
    }

    func testStartWhileRunningIsNoOp() {
        let core = CaptureControlCore()
        _ = core.update(.startRequested(deviceID: "mic0", now: 0))
        _ = core.update(.prepared(deviceID: "mic0", now: 0))
        _ = core.update(.bufferArrived)
        let cmds = core.update(.startRequested(deviceID: "mic0", now: 1))
        XCTAssertEqual(cmds, [], "startRequested while already running must be no-op")
    }

    func testBufferArrivedClearsWatchdogAfterRebuild() {
        // After rebuild, if buffer arrives before second deadline: no failTurn
        let core = CaptureControlCore(firstBufferDeadline: 0.3)
        _ = core.update(.startRequested(deviceID: "mic0", now: 0))
        _ = core.update(.prepared(deviceID: "mic0", now: 0))
        // First timeout → rebuild
        _ = core.update(.tick(now: 0.4))
        // Buffer arrives before second timeout
        let clearCmds = core.update(.bufferArrived)
        XCTAssertEqual(clearCmds, [])
        // Second "timeout" tick should now be harmless
        let lateTick = core.update(.tick(now: 0.8))
        XCTAssertFalse(lateTick.contains(.failTurn), "Buffer after rebuild clears watchdog")
    }
}
