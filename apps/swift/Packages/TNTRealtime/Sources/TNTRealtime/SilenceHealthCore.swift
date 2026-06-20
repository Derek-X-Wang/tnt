// SilenceHealthCore — pure bit-perfect-zero detector for issue #149.
//
// PROBLEM (from #136 / #146 hardware testing):
//   CaptureControlCore's zero-frame watchdog only fires when NO frames arrive.
//   A device that delivers frames full of exact zeros (e.g. AirPods HFP input,
//   stale device node) is never detected — the frames arrive normally, just silent.
//
// DESIGN:
//   Signal: exact-zero ratio / RMS variance — NOT a dB threshold.
//   A quiet user still has tiny non-zero PCM values (floor noise → non-zero variance).
//   A broken / stuck device emits bit-perfect zeros (sumOfSquares == 0.0 exactly).
//
//   The detector accumulates samples over the first `windowDuration` seconds of a
//   capture turn. If the sum-of-squares is still exactly zero when the window expires,
//   it emits `rebuildOnce` — once and only once per turn. Any non-zero sample
//   (positive sum-of-squares) immediately emits `healthy` and disarms the detector.
//
//   Pure: Foundation only, no CoreAudio / AVFoundation. Clock is injected via events
//   so the detector is synchronously testable without touching hardware.
//
//   Integration: #150 (ready-for-human) wires this into CaptureControlCore / AUHAL.

import Foundation

// MARK: - Public types

/// Verdict from the silence health detector for the current capture turn.
public enum SilenceDiagnosis: Sendable, Equatable {
    /// Device is producing real audio: at least one non-zero-variance frame was seen.
    case healthy
    /// All frames in the observation window were bit-perfect zeros.
    /// The capture pipeline should attempt a rebuild exactly once.
    case rebuildOnce
}

/// Events fed into ``SilenceHealthCore``.
public enum SilenceHealthEvent: Sendable, Equatable {
    /// A new Voice Turn capture window began. Resets all accumulated state.
    /// `now` is the injected monotonic time (seconds) — e.g. `CACurrentMediaTime()` in HITL.
    case turnStarted(now: TimeInterval)
    /// A frame of Float32 PCM samples arrived from the capture pipeline.
    /// `now` is the injected monotonic time (seconds) at which the frame was captured.
    case samplesArrived(_ samples: [Float], now: TimeInterval)
}

// MARK: - SilenceHealthCore

/// Pure reducer that detects bit-perfect-zero capture (broken device / stale node)
/// and distinguishes it from quiet-but-real audio (silent room, non-zero variance).
///
/// **Usage**
/// ```swift
/// let detector = SilenceHealthCore()
/// detector.update(.turnStarted(now: CACurrentMediaTime()))
/// // …on each captured buffer…
/// if let verdict = detector.update(.samplesArrived(pcm, now: CACurrentMediaTime())) {
///     // verdict is .healthy or .rebuildOnce
/// }
/// ```
///
/// - The clock is fully injected — no `Date()` or `CACurrentMediaTime()` calls inside.
/// - No CoreAudio / AVFoundation imports — safe to test without hardware.
/// - Not thread-safe; serialize calls externally if needed.
public final class SilenceHealthCore {

    /// Length (seconds) of the zero-variance observation window.
    /// Defaults to 0.75 s, covering the 500–1 000 ms spec range from issue #149.
    public let windowDuration: TimeInterval

    // Accumulated sum-of-squares (Double for precision on tiny Float values).
    private var sumOfSquares: Double = 0

    // Injected monotonic time when the current turn started. nil before first turnStarted.
    private var turnStartedAt: TimeInterval? = nil

    // Set to true once a verdict is emitted this turn; suppresses further output.
    private var disarmed: Bool = false

    // MARK: - Init

    public init(windowDuration: TimeInterval = 0.75) {
        self.windowDuration = windowDuration
    }

    // MARK: - Reducer

    /// Process one event and return a ``SilenceDiagnosis`` the first time a verdict
    /// can be drawn, or `nil` while still accumulating evidence.
    ///
    /// A non-nil return value is emitted at most once per turn; subsequent calls
    /// return `nil` until the next ``SilenceHealthEvent/turnStarted(now:)``.
    @discardableResult
    public func update(_ event: SilenceHealthEvent) -> SilenceDiagnosis? {
        switch event {
        case .turnStarted(let now):
            turnStartedAt = now
            sumOfSquares = 0
            disarmed = false
            return nil

        case .samplesArrived(let samples, let now):
            return handleSamples(samples, now: now)
        }
    }

    // MARK: - Private

    private func handleSamples(_ samples: [Float], now: TimeInterval) -> SilenceDiagnosis? {
        // Ignore frames before the first turnStarted or after a verdict.
        guard !disarmed, let startedAt = turnStartedAt else { return nil }

        // Accumulate sum-of-squares in Double precision.
        // This is the sole signal: if it stays at exactly 0.0, every sample
        // was a bit-perfect zero (broken device). If it exceeds 0.0, the
        // device is producing real audio — even floor noise has non-zero variance.
        for s in samples {
            sumOfSquares += Double(s) * Double(s)
        }

        // Fast path: non-zero variance seen → device is healthy; disarm immediately.
        if sumOfSquares > 0 {
            disarmed = true
            return .healthy
        }

        // Check whether the observation window has expired.
        let elapsed = now - startedAt
        guard elapsed >= windowDuration else {
            // Still inside the window; keep accumulating.
            return nil
        }

        // Window expired and every sample was a bit-perfect zero → rebuild.
        disarmed = true
        return .rebuildOnce
    }
}
