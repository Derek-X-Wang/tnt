// VoiceTurnFlow — pure state machine for one **Voice Turn** (per
// CONTEXT.md: "one round of human speech → TNT spoken reply"). The
// glue layer (`AppDelegate.VoiceTurnController` in TNTMac) feeds it
// hotkey edges and server events; the flow returns a list of
// `VoiceTurnDirective`s the glue layer carries out.
//
// Keeping the orchestration logic out of the Controller makes the
// three M0/S8 acceptance scenarios — clean turn, interrupted turn,
// transport-failure turn — replayable in unit tests without
// instantiating an `AVAudioEngine`, a `URLSessionWebSocketTask`, or
// any AppKit window.

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
}

public struct VoiceTurnFlow: Sendable, Equatable {

    public private(set) var state: AppState

    public init(state: AppState = .idle) {
        self.state = state
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

        // MARK: Errors — server-side or transport — recover to idle

        case (_, .responseError(let message)),
             (_, .transportError(let message)):
            state = .idle
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
