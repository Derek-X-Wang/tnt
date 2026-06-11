// InFlightToolRoute — pure routing policy for in-flight tool calls (issue #105, M4a).
//
// Replaces the controller's `composeInFlight: Bool` flag with a richer enum that
// distinguishes which orchestrator "owns" the next response.done:
//
//   none                           — no tool call in flight; response.done goes to VoiceTurnFlow
//   compose                        — compose round-trip owns the next response.done
//   screenToolSuppressingFunctionDone — a screen tool round-trip is in flight; the
//                                      *first* response.done (for the function_call_output
//                                      synthetic response) is suppressed by the orchestrator
//                                      and must not reach VoiceTurnFlow. After suppression
//                                      the route clears so the *second* response.done (the
//                                      spoken answer) reaches VoiceTurnFlow normally and
//                                      drives (.speaking,.responseDone) → .idle.
//
// Without the suppression + route-clear, the turn never ends: VoiceTurnFlow never
// sees the spoken-answer response.done because the route stays in the screen-tool
// state and swallows it.
//
// Pure value type — no imports beyond Foundation. All state transitions are
// expressed as mutating methods that the controller calls.

import Foundation

// MARK: - InFlightToolRoute

/// Routing policy for the currently in-flight Realtime tool call.
///
/// Determines which component "consumes" each `response.done` server event:
/// - `.none`: no tool in flight; `response.done` flows to `VoiceTurnFlow`.
/// - `.compose`: compose round-trip active; ComposeOrchestrator handles the done.
/// - `.screenToolSuppressingFunctionDone`: Tier-1 screen read active;
///   the next done is the synthetic fco-response and must be suppressed.
///   Call `markFunctionDoneSuppressed()` to advance to `.none` so the
///   subsequent spoken-answer done reaches `VoiceTurnFlow`.
public enum InFlightToolRoute: Equatable, Sendable {

    /// No tool call is currently in flight.
    case none

    /// A `compose_agent_prompt` call is in flight; its orchestrator owns the next done.
    case compose

    /// A `read_screen_text` call is in flight. The next `response.done` is for the
    /// function-call-output synthetic response and must be suppressed. After suppression
    /// the route clears to `.none` so the following spoken-answer `response.done`
    /// reaches `VoiceTurnFlow`.
    case screenToolSuppressingFunctionDone
}

// MARK: - Route helpers

extension InFlightToolRoute {

    /// Whether the current route should suppress the next `response.done`
    /// (i.e., the done event goes to the screen orchestrator, not VoiceTurnFlow).
    public var suppressesNextDone: Bool {
        self == .screenToolSuppressingFunctionDone
    }

    /// Advance the route after the suppressed function-done has been consumed.
    ///
    /// Calling this when the route is `.screenToolSuppressingFunctionDone`
    /// transitions it to `.none`, allowing the spoken-answer `response.done`
    /// to reach `VoiceTurnFlow`. No-op for any other route.
    public mutating func markFunctionDoneSuppressed() {
        guard self == .screenToolSuppressingFunctionDone else { return }
        self = .none
    }

    /// Reset to `.none` unconditionally. Called on turn-generation token advance
    /// (barge-in / new turn) to discard any stale in-flight state.
    public mutating func reset() {
        self = .none
    }
}
