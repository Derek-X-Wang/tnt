// ComposeOrchestrator — pure compose round-trip policy + stale-token guard (issue #79).
//
// Owns the compose policy that today lives inline in VoiceTurnController and cannot
// be tested because the controller depends on hardware (microphone, WebSocket).
//
// Responsibilities:
// - Run the injected `compose` closure with the mapped AgentRef/intent/raw/capture.
// - Emit `function_call_output` + `response.create` via injected hooks after compose.
// - Hold the pending Rewrite value for the deliver path.
// - Guard against stale composes: a compose result that arrives after the turn-generation
//   token advanced (barge-in / new turn) is dropped — no fco/rc reach the session.
// - Emit `.confirmationProduced` ONLY on the subsequent spoken-confirm `response.done`,
//   never synchronously when `compose` returns (emitting early would move the flow to
//   `.confirming` before the model has spoken the confirm line, causing audio to be
//   dropped because the flow would stop enqueueing `.audioDelta`).
//
// Driven entirely by injected closures/primitives:
// - compose: (AgentRef, String, String, CaptureSet) async throws -> String
// - sendFunctionCallOutput: (String, String) -> Void  (callId, output)
// - sendResponseCreate: () -> Void
// - onEvent: (ComposeOrchestratorEvent) -> Void       (optional observer)
//
// Imports only Foundation + TNTCore — no TNTRealtime, no AppKit.

import Foundation
import TNTCore

// MARK: - Events emitted by the orchestrator

/// Events emitted upward to the controller layer.
public enum ComposeOrchestratorEvent: Sendable, Equatable {
    /// Emitted on the confirm `response.done` after compose completed.
    /// The controller maps this to `VoiceTurnFlowEvent.confirmationProduced`.
    case confirmationProduced(pendingRewrite: String)
}

// MARK: - ComposeOrchestrator

/// Owns the compose round-trip policy for M1 Rewrite.
///
/// Thread-safety: this class is not `Sendable` — all methods must be called
/// from the same actor/queue as `VoiceTurnController`. Swift concurrency
/// ensures the `async` `handleDecision` call is awaited before the next
/// event arrives (the controller drives it serially).
public final class ComposeOrchestrator {

    // MARK: - Types

    public typealias ComposeFunc = (AgentRef, String, String, CaptureSet) async throws -> String
    public typealias SendFunctionCallOutput = (String, String) -> Void
    public typealias SendResponseCreate = () -> Void
    public typealias OnEvent = (ComposeOrchestratorEvent) -> Void

    // MARK: - Injected closures

    private let composeFunc: ComposeFunc
    private let sendFunctionCallOutput: SendFunctionCallOutput
    private let sendResponseCreate: SendResponseCreate
    private let onEvent: OnEvent

    // MARK: - State

    /// The pending Rewrite text, available for the deliver path after compose.
    /// Set after compose completes; cleared by the controller on delivery.
    public private(set) var pendingRewrite: String?

    /// Turn-generation token. Incremented on each new Voice Turn (barge-in,
    /// fresh turn). A compose result carrying a stale token is dropped.
    private var turnToken: UInt64 = 0

    /// Whether we are waiting for the confirm `response.done`. Set to true
    /// after compose emits fco+rc; cleared after `.confirmationProduced` fires.
    private var awaitingConfirmResponseDone: Bool = false

    // MARK: - Init

    public init(
        compose: @escaping ComposeFunc,
        sendFunctionCallOutput: @escaping SendFunctionCallOutput,
        sendResponseCreate: @escaping SendResponseCreate,
        onEvent: @escaping OnEvent = { _ in }
    ) {
        self.composeFunc = compose
        self.sendFunctionCallOutput = sendFunctionCallOutput
        self.sendResponseCreate = sendResponseCreate
        self.onEvent = onEvent
    }

    // MARK: - Turn-generation token

    /// Advance the turn-generation token. Call this when a new Voice Turn
    /// starts (hotkey press / barge-in). Any in-flight compose for the old
    /// token will be dropped on completion.
    public func advanceTurnToken() {
        turnToken &+= 1
        // A new turn also clears the pending-confirm flag — the previous
        // compose round-trip is abandoned.
        awaitingConfirmResponseDone = false
    }

    // MARK: - Decision handling

    /// Handle a `ToolCallDecision` from the controller.
    ///
    /// For `.compose`: runs the compose closure, then (if not stale) emits
    /// `function_call_output` + `response.create` and arms the orchestrator
    /// to fire `.confirmationProduced` on the next `response.done`.
    ///
    /// For `.deliver` and `.ignore`: no-op (the controller handles deliver
    /// by reading `pendingRewrite` and calling the deliver path directly).
    public func handleDecision(
        _ decision: ToolCallDecision,
        callId: String,
        capture: CaptureSet
    ) async {
        guard case .compose(let args) = decision else {
            return  // .deliver and .ignore are no-ops for the orchestrator
        }

        // Snapshot the token at the time this compose was dispatched.
        let dispatchToken = turnToken

        // Map the raw target string to a canonical AgentRef.
        let agentRef = AgentRef(key: args.target)
        let intent = args.intent
        let raw = args.rawTranscript ?? ""

        // Run the Cognitive Engine compose (may be slow — network call in production).
        let rewrite: String
        do {
            rewrite = try await composeFunc(agentRef, intent, raw, capture)
        } catch {
            // Compose failed — drop silently (the session continues without a Rewrite).
            return
        }

        // Stale-compose guard: if the turn advanced since we dispatched, drop.
        guard turnToken == dispatchToken else {
            return
        }

        // Store the pending Rewrite for the deliver path.
        pendingRewrite = rewrite

        // Emit the Realtime hooks to let the model continue speaking.
        sendFunctionCallOutput(callId, rewrite)
        sendResponseCreate()

        // Arm: wait for the spoken-confirm response.done before firing .confirmationProduced.
        awaitingConfirmResponseDone = true
    }

    // MARK: - response.done signal

    /// Called by the controller when a `response.done` server event arrives.
    ///
    /// If the orchestrator is armed (i.e. a compose just completed and emitted
    /// fco+rc), this fires `.confirmationProduced` — indicating that the model
    /// has finished speaking the confirm line. This is the one and only moment
    /// the orchestrator fires the event: never synchronously on compose return.
    ///
    /// The `responseId` and `status` fields come from the extended `ResponseDone`
    /// struct (issue #80). Currently unused here (we respond to the first
    /// response.done after arming; future work could filter by responseId).
    public func handleResponseDone(responseId: String?, status: String?) {
        guard awaitingConfirmResponseDone, let rewrite = pendingRewrite else {
            return
        }
        awaitingConfirmResponseDone = false
        onEvent(.confirmationProduced(pendingRewrite: rewrite))
    }
}
