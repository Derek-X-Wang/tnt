// CaptureControlCore — pure reducer/state machine for AUHAL capture lifecycle
// and zero-frame watchdog (issue #140).
//
// DESIGN (AC1):
//   No CoreAudio / AudioToolbox imports. No real clock access (`Date()` /
//   `clock_gettime()`). Time flows in via `tick(now:)` events only.
//   The state machine is a class wrapping a plain struct so callers
//   can drive it from any thread, test it synchronously, and inject
//   arbitrary time sequences without touching hardware.
//
// EVENT → COMMAND model:
//   `update(_:)` takes one event and returns the commands the HITL adapter
//   should execute. Commands are values; the adapter owns execution.
//
// STATE INVARIANTS:
//   • isPrepared(for:) reflects whether the unit is known-good for a device.
//   • Warm-keeping: `stopRequested` emits `stop` but does NOT tear down the
//     unit — the next `startRequested` for the same device emits `start`
//     directly (no `prepare` round-trip).
//   • Generation: a monotonically-increasing integer supplied by the HITL on
//     every hardware-topology change (sample rate / default device / channel
//     count change). A new generation marks the current prepare as stale.
//   • Watchdog: arms after `start` is emitted (time reference = `now` in the
//     triggering event). First `tick` past the deadline emits `rebuild` once;
//     a second `tick` past the (renewed) deadline emits `failTurn`. A
//     `bufferArrived` before either deadline disarms the watchdog entirely.

import Foundation

// MARK: - Public types

/// Events fed into the capture control core.
public enum CaptureControlEvent: Sendable, Equatable {
    /// Caller wants to start capturing from the given device.
    /// `now` is the caller's current monotonic timestamp (seconds).
    case startRequested(deviceID: String, now: TimeInterval)
    /// Caller wants to stop capturing (unit stays warm for the next turn).
    case stopRequested
    /// HITL adapter reports that the audio unit is ready for the given device.
    /// `now` is the caller's current monotonic timestamp.
    case prepared(deviceID: String, now: TimeInterval)
    /// HITL adapter reports that the audio unit failed to start or crashed.
    case unitFailed
    /// An audio buffer arrived from the capture unit (watchdog heartbeat).
    case bufferArrived
    /// Hardware topology changed (default device / sample rate / channel count).
    /// `generation` is a monotonically-increasing counter owned by the HITL.
    case deviceChanged(generation: Int)
    /// Periodic clock tick — the only source of "current time" in the core.
    case tick(now: TimeInterval)
}

/// Commands the HITL adapter should execute in response to events.
public enum CaptureControlCommand: Sendable, Equatable {
    /// Create / configure the audio unit for the given device.
    case prepare(deviceID: String)
    /// Start the audio unit (begin producing buffers).
    case start
    /// Stop the audio unit (keep the unit alive — warm for next turn).
    case stop
    /// Tear down the audio unit completely.
    case reset
    /// Rebuild: tear down + recreate the audio unit (hardware issue recovery).
    case rebuild
    /// Surface a "didn't catch that" error to the Voice Turn layer.
    case failTurn
}

// MARK: - Core state (private)

private enum Phase: Equatable {
    case idle
    case preparing(deviceID: String)
    case warm(deviceID: String)         // prepared + stopped, ready for fast start
    case running(deviceID: String)      // started, producing buffers
}

private struct Watchdog: Equatable {
    var startedAt: TimeInterval         // when start was emitted
    let deadline: TimeInterval          // first-buffer deadline (seconds)
    var hasRebuilt: Bool = false        // true after the first rebuild attempt
}

private struct CoreState: Equatable {
    var phase: Phase = .idle
    var isDirty: Bool = false           // true when device topology changed
    var currentGeneration: Int = 0
    var watchdog: Watchdog? = nil
}

// MARK: - CaptureControlCore

/// Pure reducer / state machine for AUHAL capture lifecycle + zero-frame watchdog.
///
/// Feed events via ``update(_:)``; execute the returned commands in the HITL adapter.
/// No CoreAudio types; no real-time clock; fully unit-testable.
public final class CaptureControlCore {

    /// First-buffer deadline: if no `bufferArrived` within this many seconds of
    /// emitting `start`, the watchdog fires `rebuild`.  Default (~500 ms) is
    /// intentionally conservative; tune on hardware in the HITL adapter.
    public let firstBufferDeadline: TimeInterval

    private var state = CoreState()

    public init(firstBufferDeadline: TimeInterval = 0.5) {
        self.firstBufferDeadline = firstBufferDeadline
    }

    // MARK: - Reducer

    /// Process one event and return the commands the HITL adapter must execute.
    /// Not thread-safe — serialize calls externally if needed.
    @discardableResult
    public func update(_ event: CaptureControlEvent) -> [CaptureControlCommand] {
        switch event {

        case .startRequested(let deviceID, let now):
            return handleStartRequested(deviceID: deviceID, now: now)

        case .stopRequested:
            return handleStopRequested()

        case .prepared(let deviceID, let now):
            return handlePrepared(deviceID: deviceID, now: now)

        case .unitFailed:
            state.phase = .idle
            state.watchdog = nil
            state.isDirty = false
            return [.reset]

        case .bufferArrived:
            // Disarm watchdog — audio is flowing.
            state.watchdog = nil
            return []

        case .deviceChanged(let generation):
            return handleDeviceChanged(generation: generation)

        case .tick(let now):
            return handleTick(now: now)
        }
    }

    // MARK: - isPrepared

    /// Returns `true` when the audio unit is already prepared for `deviceID`
    /// (warm or running) — meaning the next `startRequested` for this device
    /// will not need a `prepare` round-trip.
    public func isPrepared(for deviceID: String) -> Bool {
        switch state.phase {
        case .warm(let id), .running(let id):
            return id == deviceID && !state.isDirty
        case .idle, .preparing:
            return false
        }
    }

    // MARK: - Private helpers

    private func handleStartRequested(deviceID: String, now: TimeInterval) -> [CaptureControlCommand] {
        switch state.phase {

        case .idle:
            // Cold start: request unit preparation.
            state.phase = .preparing(deviceID: deviceID)
            return [.prepare(deviceID: deviceID)]

        case .preparing(let currentDevice):
            if currentDevice == deviceID {
                // Idempotent: already preparing this device (AC2).
                return []
            } else {
                // New device requested while preparing: switch target.
                state.phase = .preparing(deviceID: deviceID)
                return [.prepare(deviceID: deviceID)]
            }

        case .warm(let currentDevice):
            if currentDevice == deviceID && !state.isDirty {
                // Warm-keeping (AC3): unit already prepared for this device,
                // not dirty — emit start directly, no prepare needed.
                state.phase = .running(deviceID: deviceID)
                armWatchdog(startedAt: now)
                return [.start]
            } else {
                // Device changed or dirty: clean rebuild.
                state.phase = .preparing(deviceID: deviceID)
                state.isDirty = false
                return [.reset, .prepare(deviceID: deviceID)]
            }

        case .running:
            // Already running — no-op (idempotent).
            return []
        }
    }

    private func handleStopRequested() -> [CaptureControlCommand] {
        switch state.phase {
        case .running(let deviceID):
            // Stop but keep the unit warm (no teardown). Disarm watchdog.
            state.phase = .warm(deviceID: deviceID)
            state.watchdog = nil
            return [.stop]
        case .warm, .preparing, .idle:
            // Idempotent (AC6): already stopped / not started.
            return []
        }
    }

    private func handlePrepared(deviceID: String, now: TimeInterval) -> [CaptureControlCommand] {
        guard case .preparing(let targetDevice) = state.phase,
              targetDevice == deviceID else {
            // Stale prepared event (e.g. device changed during preparation).
            return []
        }
        // Unit ready: start immediately.
        state.phase = .running(deviceID: deviceID)
        armWatchdog(startedAt: now)
        return [.start]
    }

    private func handleDeviceChanged(generation: Int) -> [CaptureControlCommand] {
        // Idempotent for the same generation (AC5).
        guard generation != state.currentGeneration else { return [] }
        state.currentGeneration = generation
        state.isDirty = true

        switch state.phase {
        case .running(let deviceID):
            // Mid-turn device change: invalidate pending audio, trigger rebuild.
            // The unit will be re-prepared on the next startRequested.
            state.phase = .warm(deviceID: deviceID)
            state.watchdog = nil
            return [.rebuild]
        case .idle, .preparing, .warm:
            // Not running: just mark dirty. Re-prepare on next startRequested.
            return []
        }
    }

    private func handleTick(now: TimeInterval) -> [CaptureControlCommand] {
        guard var wd = state.watchdog else { return [] }

        let elapsed = now - wd.startedAt
        guard elapsed >= wd.deadline else { return [] }

        if wd.hasRebuilt {
            // Second timeout with no buffer → surface failure (AC4).
            state.watchdog = nil
            state.phase = .idle
            return [.failTurn]
        } else {
            // First timeout → try rebuild, renew the deadline (AC4).
            wd.hasRebuilt = true
            wd.startedAt = now   // reset deadline from this tick
            state.watchdog = wd
            return [.rebuild]
        }
    }

    private func armWatchdog(startedAt: TimeInterval) {
        state.watchdog = Watchdog(
            startedAt: startedAt,
            deadline: firstBufferDeadline
        )
    }
}
