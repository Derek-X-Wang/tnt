// VoiceTurnFlow — pure state machine for one **Voice Turn** (per
// CONTEXT.md: "one round of human speech → TNT spoken reply"). The
// glue layer (`AppDelegate.VoiceTurnController` in TNTMac) feeds it
// hotkey edges and server events; the flow returns a list of
// `VoiceTurnDirective`s the glue layer carries out.
//
// Keeping the orchestration logic out of the Controller makes the
// M0/S8 acceptance scenarios — clean turn, interrupted turn,
// transport-failure turn — and the M1 confirmation scenarios all
// replayable in unit tests without instantiating an `AVAudioEngine`,
// a `URLSessionWebSocketTask`, or any AppKit window.
//
// M1 addition (issue #46): a `confirming` state holds a pending Rewrite
// between TNT speaking "…confirm?" and the User answering. Delivery is
// exactly once: only an explicit `userAffirmed` event in the `confirming`
// state emits `deliverRewrite`; any other transition clears the pending
// Rewrite without delivering it.

import Foundation

/// Inputs the flow reacts to.
public enum VoiceTurnFlowEvent: Sendable, Equatable {
    /// User started a Voice Turn (hold-down or tap-on).
    case hotkeyStartListening
    /// User ended a Voice Turn (release or tap-off).
    case hotkeyStopListening
    /// Server emitted `response.audio.delta`. Payload is the base64
    /// chunk that gets enqueued on the player.
    case audioDelta(String)
    /// Server emitted `response.done`.
    case responseDone
    /// Server emitted `error`. Carries a one-line message.
    case responseError(String)
    /// WS transport failed (connection lost, etc.).
    case transportError(String)

    // MARK: - M1 confirmation events

    /// The Cognitive Engine produced a cleaned Rewrite and the model
    /// has spoken it back asking for confirmation. The flow moves into
    /// `.confirming`, holding the pending Rewrite until the User affirms
    /// or declines.
    case confirmationProduced(pendingRewrite: String)

    /// The User affirmed the pending Rewrite ("yes" / "对" / "好" etc —
    /// bilingual detection is the Realtime model's responsibility, not
    /// the flow's). Triggers exactly-once delivery.
    case userAffirmed

    /// The User declined the pending Rewrite ("no" / "cancel" etc).
    /// The pending Rewrite is discarded without delivery.
    case userDeclined
}

/// Side effects the glue layer carries out. Order matters — the
/// Controller iterates this list and runs each effect in sequence.
public enum VoiceTurnDirective: Sendable, Equatable {
    case setState(AppState)
    case startCapture
    case stopCapture
    /// Send `input_audio_buffer.commit` followed by `response.create`.
    case sendCommitAndCreate
    /// Send `response.cancel` followed by `input_audio_buffer.clear`.
    case sendCancelAndClear
    case enqueuePlayback(String)   // base64 PCM16
    case stopPlayer
    case restartPlayer
    case showError(String)

    // MARK: - M1 confirmation directives

    /// Deliver the pending Rewrite exactly once: write it to the
    /// pasteboard / send it to the target Worker Agent. The Controller
    /// must only act on this directive once; subsequent `userAffirmed`
    /// events in a non-confirming state are no-ops (see the flow logic).
    case deliverRewrite(String)
}

public struct VoiceTurnFlow: Sendable, Equatable {

    public private(set) var state: AppState

    /// The pending Rewrite text held during `.confirming`. Set when
    /// `confirmationProduced` fires; cleared on any transition out of
    /// `.confirming`, whether affirmed or not.
    public private(set) var pendingRewrite: String?

    public init(state: AppState = .idle) {
        self.state = state
        self.pendingRewrite = nil
    }

    /// Apply an event and return the list of side effects for the
    /// glue layer to carry out.
    public mutating func handle(_ event: VoiceTurnFlowEvent) -> [VoiceTurnDirective] {
        switch (state, event) {

        // MARK: Begin / end a Voice Turn

        case (.idle, .hotkeyStartListening),
             (.thinking, .hotkeyStartListening):
            state = .listening
            return [.setState(.listening), .startCapture]

        case (.listening, .hotkeyStopListening):
            state = .thinking
            return [.stopCapture, .sendCommitAndCreate, .setState(.thinking)]

        // MARK: Server response stream

        case (.thinking, .audioDelta(let payload)):
            state = .speaking
            return [.setState(.speaking), .enqueuePlayback(payload)]

        case (.speaking, .audioDelta(let payload)):
            return [.enqueuePlayback(payload)]

        case (.thinking, .responseDone),
             (.speaking, .responseDone):
            state = .idle
            return [.setState(.idle)]

        // MARK: Interrupt — hold while server is speaking

        case (.speaking, .hotkeyStartListening):
            state = .listening
            return [
                .sendCancelAndClear,
                .stopPlayer,
                .restartPlayer,
                .setState(.listening),
                .startCapture,
            ]

        // MARK: M1: Confirmation flow

        /// The model produced a Rewrite and spoke it; move to confirming.
        case (.speaking, .confirmationProduced(let rewrite)),
             (.thinking, .confirmationProduced(let rewrite)):
            state = .confirming
            pendingRewrite = rewrite
            return [.setState(.confirming)]

        /// User affirmed — deliver exactly once and return to idle.
        case (.confirming, .userAffirmed):
            guard let rewrite = pendingRewrite else {
                // Defensive: pendingRewrite should always be set when confirming.
                state = .idle
                return [.setState(.idle)]
            }
            state = .idle
            pendingRewrite = nil
            return [.deliverRewrite(rewrite), .setState(.idle)]

        /// User declined — discard without delivery.
        case (.confirming, .userDeclined):
            state = .idle
            pendingRewrite = nil
            return [.setState(.idle)]

        /// New Voice Turn started while confirming — supersede the pending
        /// Rewrite without delivering it (no carry-over "yes" on a stale prompt).
        case (.confirming, .hotkeyStartListening):
            state = .listening
            pendingRewrite = nil
            return [.setState(.listening), .startCapture]

        // MARK: Errors — server-side or transport — recover to idle

        case (_, .responseError(let message)),
             (_, .transportError(let message)):
            state = .idle
            pendingRewrite = nil
            return [
                .showError(message),
                .stopCapture,
                .stopPlayer,
                .restartPlayer,
                .setState(.idle),
            ]

        // MARK: Spurious / impossible — defensively no-op

        default:
            return []
        }
    }
}
