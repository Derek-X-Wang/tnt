// HotkeyGestureRecognizer — pure state machine that turns a stream of
// `keyDown`/`keyUp` events on the configured chord into State Lamp
// effects. Lives outside `HotkeyHost` so the hold-vs-tap rules can be
// exhaustively tested without instantiating a `CGEventTap`.
//
// Semantics (per docs/roadmap.md M0/S3 acceptance):
//   * Tap = `keyDown` → `keyUp` within `holdThreshold` (default 250ms).
//     Each tap inverts a latch — first tap turns listening on, next tap
//     turns it off.
//   * Hold = `keyDown` → `keyUp` ≥ `holdThreshold`. Releasing a hold
//     always returns the lamp to `.idle`, and clears any tap latch.
//
// `keyDown` always flips the lamp on so the user gets instant visual
// feedback before the recognizer knows whether they're tapping or
// holding. The latch (or hold release) finalises the resting state on
// `keyUp`.

import Foundation

public struct HotkeyGestureRecognizer: Sendable, Equatable {

    /// Visible side-effect for the State Lamp.
    public enum Effect: Sendable, Equatable {
        case startListening
        case stopListening
        case noChange
    }

    public struct Configuration: Sendable, Equatable {
        /// Threshold (seconds) above which a press is treated as a hold.
        /// Default 250ms matches the acceptance criterion.
        public var holdThreshold: TimeInterval

        public init(holdThreshold: TimeInterval = 0.250) {
            self.holdThreshold = holdThreshold
        }
    }

    public private(set) var isListening: Bool
    public private(set) var tapToggled: Bool
    private let configuration: Configuration
    private var keyDownTime: TimeInterval?

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        self.isListening = false
        self.tapToggled = false
        self.keyDownTime = nil
    }

    /// Apply a `keyDown` for the configured chord. Auto-repeat events
    /// (`keyDown` arriving while a previous `keyDown` is still open) are
    /// collapsed so a held key registers as a single press, not many.
    public mutating func keyDown(at time: TimeInterval) -> Effect {
        guard keyDownTime == nil else { return .noChange }
        keyDownTime = time
        guard !isListening else { return .noChange }
        isListening = true
        return .startListening
    }

    /// Apply a `keyUp` for the configured chord. The duration since the
    /// last unmatched `keyDown` decides tap vs hold.
    public mutating func keyUp(at time: TimeInterval) -> Effect {
        guard let downTime = keyDownTime else { return .noChange }
        keyDownTime = nil
        let duration = time - downTime

        if duration < configuration.holdThreshold {
            // Tap — invert the latch.
            tapToggled.toggle()
            if tapToggled {
                if !isListening {
                    isListening = true
                    return .startListening
                }
                return .noChange
            } else {
                if isListening {
                    isListening = false
                    return .stopListening
                }
                return .noChange
            }
        } else {
            // Hold — always end listening, clear the latch.
            tapToggled = false
            if isListening {
                isListening = false
                return .stopListening
            }
            return .noChange
        }
    }

    /// External cancel — used when the app loses focus mid-press or
    /// when the menu's "Stop listening" affordance fires. Resets every
    /// piece of state to a clean idle.
    public mutating func cancel() -> Effect {
        keyDownTime = nil
        tapToggled = false
        if isListening {
            isListening = false
            return .stopListening
        }
        return .noChange
    }
}
