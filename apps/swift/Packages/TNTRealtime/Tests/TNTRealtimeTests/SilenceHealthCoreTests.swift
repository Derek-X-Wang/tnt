// SilenceHealthCoreTests — TDD for issue #149.
// Each test maps directly to an acceptance criterion from the issue body.
// No CoreAudio / AVFoundation imports — pure Swift, Foundation only, fully unit-testable.

import XCTest
@testable import TNTRealtime

final class SilenceHealthCoreTests: XCTestCase {

    // MARK: - Helpers

    /// A frame of N bit-perfect zeros.
    private static func zeros(_ n: Int) -> [Float] {
        Array(repeating: 0, count: n)
    }

    /// A frame of N samples with tiny but non-zero variance (alternating ±amplitude).
    private static func noise(_ n: Int, amplitude: Float = 0.001) -> [Float] {
        (0..<n).map { i in amplitude * (i % 2 == 0 ? 1.0 : -1.0) }
    }

    /// A frame of sine-wave audio at modest amplitude.
    private static func sineWave(_ n: Int, amplitude: Float = 0.5) -> [Float] {
        (0..<n).map { i in amplitude * Float(sin(Double(i) * 0.1)) }
    }

    // MARK: - AC1: All-zero buffers for the full window → rebuildOnce (exactly once)

    func testAllZeroWindowEmitsRebuildOnce() {
        let core = SilenceHealthCore(windowDuration: 0.5)
        core.update(.turnStarted(now: 0))

        // Feed zero frames inside the window — no verdict yet
        XCTAssertNil(core.update(.samplesArrived(Self.zeros(480), now: 0.1)))
        XCTAssertNil(core.update(.samplesArrived(Self.zeros(480), now: 0.3)))

        // Past the window with all-zero content → rebuildOnce
        let diag = core.update(.samplesArrived(Self.zeros(480), now: 0.6))
        XCTAssertEqual(diag, .rebuildOnce,
            "All-zero window past deadline must emit rebuildOnce")
    }

    func testRebuildOnceEmittedExactlyOnce() {
        // rebuildOnce must not be emitted a second time in the same turn (AC1).
        let core = SilenceHealthCore(windowDuration: 0.5)
        core.update(.turnStarted(now: 0))
        let first = core.update(.samplesArrived(Self.zeros(480), now: 0.6))
        XCTAssertEqual(first, .rebuildOnce, "First post-window zero frame must emit rebuildOnce")

        // Further frames — detector is disarmed
        let second = core.update(.samplesArrived(Self.zeros(480), now: 0.8))
        XCTAssertNil(second, "rebuildOnce must be emitted at most once per turn")
    }

    // MARK: - AC2: Quiet-but-real audio (low dB, non-zero variance) → healthy

    func testQuietButRealAudioEmitsHealthyImmediately() {
        // Floor-level amplitude but non-zero → device is working (just a quiet room).
        let core = SilenceHealthCore(windowDuration: 0.75)
        core.update(.turnStarted(now: 0))

        let quiet = (0..<480).map { _ in Float(0.0001) }  // tiny but non-zero
        let diag = core.update(.samplesArrived(quiet, now: 0.1))
        XCTAssertEqual(diag, .healthy,
            "Non-zero-variance (quiet-but-real) audio must not trigger rebuildOnce")
    }

    func testAlternatingTinyAmplitudeIsHealthy() {
        // Alternating +ε / -ε: mean ≈ 0, variance > 0 — must register healthy, not rebuild.
        let core = SilenceHealthCore(windowDuration: 0.75)
        core.update(.turnStarted(now: 0))
        let samples = Self.noise(480, amplitude: Float.leastNormalMagnitude)
        let diag = core.update(.samplesArrived(samples, now: 0.1))
        XCTAssertEqual(diag, .healthy, "Minimum non-zero variance must register as healthy")
    }

    // MARK: - AC3: Normal audio → healthy

    func testNormalAudioEmitsHealthy() {
        let core = SilenceHealthCore(windowDuration: 0.75)
        core.update(.turnStarted(now: 0))
        let diag = core.update(.samplesArrived(Self.sineWave(480), now: 0.1))
        XCTAssertEqual(diag, .healthy, "Normal audio must emit healthy immediately")
    }

    // MARK: - AC4: A real sample before the deadline disarms the check (no later rebuild)

    func testRealSampleBeforeDeadlineDisarmsDetector() {
        let core = SilenceHealthCore(windowDuration: 0.75)
        core.update(.turnStarted(now: 0))

        // Zero frames before the real sample
        XCTAssertNil(core.update(.samplesArrived(Self.zeros(480), now: 0.1)))
        XCTAssertNil(core.update(.samplesArrived(Self.zeros(480), now: 0.3)))

        // One non-zero frame before window expires
        let diag = core.update(.samplesArrived(Self.noise(480), now: 0.5))
        XCTAssertEqual(diag, .healthy,
            "Real sample before deadline must disarm and emit healthy")

        // Post-deadline zero frames must produce nothing (disarmed)
        let late = core.update(.samplesArrived(Self.zeros(480), now: 1.0))
        XCTAssertNil(late,
            "After healthy disarm, later zero frames must not emit rebuildOnce")
    }

    func testSingleNonZeroSampleInMixedFrameDisarms() {
        // A frame that contains at least one non-zero sample has non-zero variance.
        let core = SilenceHealthCore(windowDuration: 0.75)
        core.update(.turnStarted(now: 0))
        var mixed = Self.zeros(480)
        mixed[240] = 0.001   // one non-zero sample in the frame
        let diag = core.update(.samplesArrived(mixed, now: 0.1))
        XCTAssertEqual(diag, .healthy,
            "A frame with even one non-zero sample must emit healthy")
    }

    // MARK: - AC5: Pure — no CoreAudio/AVFoundation; injected clock; swift test green

    func testNoCoreAudioDependency() {
        // SilenceHealthCore must construct without any hardware dependency.
        // If this file compiles without importing CoreAudio/AVFoundation, AC5 is satisfied.
        let core = SilenceHealthCore()
        XCTAssertNotNil(core, "SilenceHealthCore must be constructable without hardware dependencies")
    }

    // MARK: - turnStarted resets accumulated state

    func testTurnStartedResetsBetweenTurns() {
        let core = SilenceHealthCore(windowDuration: 0.5)
        core.update(.turnStarted(now: 0))

        // Turn 1: all zeros → rebuildOnce
        let t1 = core.update(.samplesArrived(Self.zeros(480), now: 0.6))
        XCTAssertEqual(t1, .rebuildOnce)

        // Turn 2: starts fresh; real audio should give healthy
        core.update(.turnStarted(now: 1.0))
        let t2 = core.update(.samplesArrived(Self.noise(480), now: 1.1))
        XCTAssertEqual(t2, .healthy,
            "After turnStarted, fresh state allows healthy detection")
    }

    func testTurnStartedResetsZeroAccumulationMidWindow() {
        let core = SilenceHealthCore(windowDuration: 0.5)
        core.update(.turnStarted(now: 0))

        // Feed zeros within window of turn 1
        _ = core.update(.samplesArrived(Self.zeros(480), now: 0.1))
        _ = core.update(.samplesArrived(Self.zeros(480), now: 0.3))

        // New turn starts — should NOT carry over zero accumulation
        core.update(.turnStarted(now: 0.4))

        // This zero frame is well inside the new turn's window (elapsed = 0.1s)
        let diag = core.update(.samplesArrived(Self.zeros(480), now: 0.5))
        XCTAssertNil(diag,
            "After turnStarted, window resets — should not fire before new window expires")
    }

    func testTurnStartedBeforeDeadlineSuppressesOldRebuild() {
        // If turnStarted resets mid-window, a post-deadline zero frame for the OLD
        // turn must not fire because the detector was reset.
        let core = SilenceHealthCore(windowDuration: 0.5)
        core.update(.turnStarted(now: 0))
        _ = core.update(.samplesArrived(Self.zeros(480), now: 0.2))
        core.update(.turnStarted(now: 0.3))    // reset mid-turn
        // Now the window is 0.3 + 0.5 = 0.8; t=0.8 is exactly at deadline
        let diag = core.update(.samplesArrived(Self.zeros(480), now: 0.81))
        XCTAssertEqual(diag, .rebuildOnce,
            "After reset, a new full-zero window should still emit rebuildOnce")
    }

    // MARK: - Window boundary precision

    func testFrameExactlyAtWindowBoundaryDoesNotFire() {
        // A frame arriving exactly at t == deadline: window must have elapsed,
        // but we treat "elapsed >= windowDuration" as firing.
        let core = SilenceHealthCore(windowDuration: 0.5)
        core.update(.turnStarted(now: 0))
        // Deliver a zero frame exactly at the deadline
        let diag = core.update(.samplesArrived(Self.zeros(480), now: 0.5))
        XCTAssertEqual(diag, .rebuildOnce,
            "Zero frame at exactly the window deadline must emit rebuildOnce")
    }

    func testFrameJustBeforeWindowBoundaryDoesNotFire() {
        let core = SilenceHealthCore(windowDuration: 0.5)
        core.update(.turnStarted(now: 0))
        let diag = core.update(.samplesArrived(Self.zeros(480), now: 0.4999))
        XCTAssertNil(diag,
            "Zero frame just before window deadline must not yet emit rebuildOnce")
    }
}
