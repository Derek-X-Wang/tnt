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
// M1 (issue #82): confirm-channel rewrite — hold-hotkey-to-confirm,
// pendingRewrite decoupled from AppState:
//
// - In `.confirming`, a hotkey press PRESERVES pendingRewrite and starts
//   capture. The model then hears the user's affirmation or decline.
// - `.userAffirmed` delivers the pending Rewrite whenever one is set
//   (not only while `.confirming`) — the model calls deliver_prompt on a
//   heard affirmation, which may arrive in .thinking/.speaking state.
// - A new `compose`/.confirmationProduced while a Rewrite is pending
//   OVERWRITES it (re-confirm the new prompt).
// - A confirm-capture turn that produces no tool call discards the pending
//   Rewrite on `response.done` (decline-by-omission).
// - VAD stays off (turn_detection: null is a fixed v0 invariant per ADR).

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
    /// has spoken it back asking for confirmation. The pending Rewrite
    /// is stored (or overwritten if already set). The flow moves into
    /// `.confirming`.
    case confirmationProduced(pendingRewrite: String)

    /// The User affirmed the pending Rewrite ("yes" / "对" / "好" etc —
    /// bilingual detection is the Realtime model's responsibility, not
    /// the flow's). Triggers exactly-once delivery when a pending Rewrite
    /// is set, regardless of which AppState the flow is currently in.
    case userAffirmed

    /// The User explicitly declined the pending Rewrite ("no" / "cancel"
    /// etc). The pending Rewrite is discarded without delivery.
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
    /// must only act on this directive once; the flow clears pendingRewrite
    /// immediately after emitting this directive so subsequent userAffirmed
    /// events with no pending Rewrite are no-ops.
    case deliverRewrite(String)
}

public struct VoiceTurnFlow: Sendable, Equatable {

    public private(set) var state: AppState

    /// The pending Rewrite text. Set when `confirmationProduced` fires;
    /// cleared on delivery, explicit decline, or any error/transport failure.
    /// Decoupled from AppState: persists across .confirming → .listening → .thinking
    /// so the user can hold the hotkey to speak their affirmation and still have
    /// the Rewrite available when the model calls deliver_prompt.
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

        case (.idle, .hotkeyStartListening):
            state = .listening
            return [.setState(.listening), .startCapture]

        // Barge-in from .thinking: cancel the in-flight response before
        // starting a new capture. No playback flush — nothing is playing yet.
        // This is analogous to the .speaking interrupt (issue #68 fix).
        case (.thinking, .hotkeyStartListening):
            state = .listening
            return [.sendCancelAndClear, .setState(.listening), .startCapture]

        case (.listening, .hotkeyStopListening):
            state = .thinking
            return [.stopCapture, .sendCommitAndCreate, .setState(.thinking)]

        // MARK: Server response stream

        case (.thinking, .audioDelta(let payload)):
            state = .speaking
            return [.setState(.speaking), .enqueuePlayback(payload)]

        case (.speaking, .audioDelta(let payload)):
            return [.enqueuePlayback(payload)]

        // response.done from thinking/speaking when there is a pending Rewrite
        // and no tool call arrived → decline-by-omission (discard the Rewrite).
        case (.thinking, .responseDone),
             (.speaking, .responseDone):
            pendingRewrite = nil
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

        /// The model produced a Rewrite and spoke it (or is speaking it).
        /// Store or overwrite the pending Rewrite; move to .confirming.
        case (.speaking, .confirmationProduced(let rewrite)),
             (.thinking, .confirmationProduced(let rewrite)),
             (.confirming, .confirmationProduced(let rewrite)):
            state = .confirming
            pendingRewrite = rewrite
            return [.setState(.confirming)]

        /// In .confirming, hotkey press PRESERVES the pending Rewrite and
        /// starts capture. The model hears the affirmation / decline speech.
        case (.confirming, .hotkeyStartListening):
            state = .listening
            // pendingRewrite intentionally NOT cleared — preserved for delivery.
            return [.setState(.listening), .startCapture]

        /// .userAffirmed delivers the pending Rewrite whenever one is set.
        /// Works in any state because the model may call deliver_prompt while
        /// the flow is .thinking or .speaking (the confirm-capture response
        /// is still in flight when the tool call arrives).
        case (_, .userAffirmed):
            guard let rewrite = pendingRewrite else {
                // No pending Rewrite — no-op.
                return []
            }
            let previous = state
            state = .idle
            pendingRewrite = nil
            var directives: [VoiceTurnDirective] = [.deliverRewrite(rewrite)]
            if previous != .idle {
                directives.append(.setState(.idle))
            }
            return directives

        /// User explicitly declined — discard without delivery.
        case (.confirming, .userDeclined):
            state = .idle
            pendingRewrite = nil
            return [.setState(.idle)]

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
