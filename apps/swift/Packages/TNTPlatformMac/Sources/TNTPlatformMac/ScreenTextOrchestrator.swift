// ScreenTextOrchestrator — Tier-1 read_screen_text round-trip policy (issue #105, M4a).
//
// Owns the screen-text policy that mirrors ComposeOrchestrator (issue #79) in
// structure: injected closures, stale-turn-token guard, no hardware/network deps.
//
// Responsibilities:
// - Resolve sources via injected `resolveSources` closure (armed-else-fresh
//   decision already encoded in the ScreenSourceResolver layer).
// - Build the snapshot JSON via injected `buildSnapshot` closure.
// - Emit `function_call_output` then `response.create` — both are mandatory;
//   a tool call without its output stalls the Realtime turn permanently.
// - Stale-turn-token guard for consistency with ComposeOrchestrator: a result
//   that arrives after the token advanced (barge-in) is dropped — nothing sent.
// - Tier 1 NEVER consumes armed Appshots (that is M4b's role).
//
// Driven entirely by injected closures:
// - resolveSources: () -> [Appshot]              armed-or-fresh slice
// - buildSnapshot: (String?, [Appshot]) -> String fco JSON body
// - sendFunctionCallOutput: (String, String) -> Void  (callId, snapshotJSON)
// - sendResponseCreate: () -> Void
//
// Imports only Foundation + TNTCore — no TNTRealtime, no AppKit.

import Foundation
import TNTCore

// MARK: - ScreenTextOrchestrator

/// Owns the Tier-1 `read_screen_text` round-trip policy.
///
/// Thread-safety: this class is not `Sendable` — all methods must be called
/// from the same actor/queue as the controller. The `async` `handleDecision`
/// is awaited serially by the controller, matching ComposeOrchestrator.
public final class ScreenTextOrchestrator {

    // MARK: - Types

    public typealias ResolveSources    = () -> [Appshot]
    public typealias BuildSnapshot     = (String?, [Appshot]) -> String
    public typealias SendFunctionCallOutput = (String, String) -> Void
    public typealias SendResponseCreate    = () -> Void

    // MARK: - Injected closures

    private let resolveSources: ResolveSources
    private let buildSnapshot: BuildSnapshot
    private let sendFunctionCallOutput: SendFunctionCallOutput
    private let sendResponseCreate: SendResponseCreate

    // MARK: - State

    /// Turn-generation token. Incremented on each new Voice Turn (barge-in,
    /// fresh turn). A result carrying a stale token is dropped.
    private var turnToken: UInt64 = 0

    // MARK: - Init

    public init(
        resolveSources: @escaping ResolveSources,
        buildSnapshot: @escaping BuildSnapshot,
        sendFunctionCallOutput: @escaping SendFunctionCallOutput,
        sendResponseCreate: @escaping SendResponseCreate
    ) {
        self.resolveSources = resolveSources
        self.buildSnapshot = buildSnapshot
        self.sendFunctionCallOutput = sendFunctionCallOutput
        self.sendResponseCreate = sendResponseCreate
    }

    // MARK: - Turn-generation token

    /// Advance the turn-generation token. Call when a new Voice Turn starts
    /// (hotkey press / barge-in). Any in-flight screen read for the old token
    /// will be dropped on completion.
    public func advanceTurnToken() {
        turnToken &+= 1
    }

    // MARK: - Decision handling

    /// Handle a `.readScreen` `ToolCallDecision` from the controller.
    ///
    /// Resolves sources, builds the snapshot JSON (synchronous in M4a — no
    /// async AX calls), and emits `function_call_output` + `response.create`
    /// if the turn token is still current.
    ///
    /// For any other decision kind, this is a no-op.
    public func handleDecision(
        _ decision: ToolCallDecision,
        callId: String
    ) async {
        guard case .readScreen(let args) = decision else {
            return  // compose, deliver, ignore are no-ops
        }

        // Snapshot the token at dispatch time.
        let dispatchToken = turnToken

        // Resolve the source Appshots (armed-else-fresh).
        // This closure is synchronous in M4a (no async AX calls).
        let sources = resolveSources()

        // Build the snapshot JSON. Also synchronous in M4a.
        let snapshotJSON = buildSnapshot(args.question, sources)

        // Stale-turn guard: if barge-in occurred while resolving/building, drop.
        guard turnToken == dispatchToken else {
            return
        }

        // Emit the mandatory handshake: fco must precede response.create.
        sendFunctionCallOutput(callId, snapshotJSON)
        sendResponseCreate()
    }
}
