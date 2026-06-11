// VisionOrchestrator — Tier-2 `analyze_screen` round-trip policy (issue #126, M4b).
//
// Mirrors ScreenTextOrchestrator (stale-token guard, injected closures) with
// three counsel-hardened differences:
//
// 1. Consume-on-success with resolve-time identity:
//    Appshot ids are captured at dispatch time. On success, consume fires
//    with exactly those ids — new Appshots armed mid-call survive.
//    The current fresh grab is NEVER consumed (turn-scoped already).
//
// 2. Stale vs active-error split (counsel P1):
//    - Barge-in (token advanced during async call) → DROP silently:
//      no fco, no rc, no consume.
//    - Engine throws while call is still current → emit error-shaped fco
//      + response.create: an unanswered active tool call wedges the Realtime
//      turn. Consume is NOT fired on error.
//
// 3. No TNTCognitive/ScreenCaptureKit/AppKit import:
//    The vision call itself is an injected `answerAboutScreen` closure.
//    The caller wires the concrete CognitiveEngine at the composition root.
//
// Per ADR-0003: composition root (TNTMac) is the only site that creates the
// concrete CognitiveEngine; VisionOrchestrator depends on an async closure,
// not the protocol directly.

import Foundation
import TNTCore

// MARK: - VisionOrchestrator

/// Orchestrates the Tier-2 `analyze_screen` tool call round-trip.
///
/// Stateful (turn token): create once per VoiceTurnController, call
/// `advanceTurnToken()` on every barge-in / turn-end to invalidate in-flight
/// calls. Thread-safety: the orchestrator is an actor; callers must `await`.
public actor VisionOrchestrator {

    // MARK: - Injected

    /// Resolve the current screen sources at dispatch time.
    private let resolveSources: () -> ResolvedScreenSources

    /// Call the vision Cognitive Engine. Injected so tests replay without network.
    /// - Parameters:
    ///   - question: The user's question from the `analyze_screen` tool arguments.
    ///   - appshots: The resolved Appshots at dispatch time.
    /// - Returns: The model's plain-text answer.
    /// - Throws: On transport error, HTTP error, or empty model response.
    private let answerAboutScreen: (String?, [Appshot]) async throws -> String

    /// Send a `function_call_output` event to the Realtime session.
    /// - Parameters:
    ///   - callId: The tool call ID from the Realtime message.
    ///   - output: The JSON or text payload to return to the model.
    private let sendFunctionCallOutput: (String, String) -> Void

    /// Send a `response.create` event to continue the Realtime turn.
    private let sendResponseCreate: () -> Void

    /// Consume armed Appshots from the store by id. Called on success only.
    /// The closure removes matching ids from `ArmedAppshotStore`.
    private let consumeArmed: (Set<UUID>) -> Void

    // MARK: - Turn token

    /// Incremented on every `advanceTurnToken()` call (barge-in, turn-end).
    /// In-flight calls capture the token at dispatch time and check it at
    /// completion — if advanced, the call is stale and dropped silently.
    private var turnToken: Int = 0

    // MARK: - Init

    public init(
        resolveSources: @escaping () -> ResolvedScreenSources,
        answerAboutScreen: @escaping (String?, [Appshot]) async throws -> String,
        sendFunctionCallOutput: @escaping (String, String) -> Void,
        sendResponseCreate: @escaping () -> Void,
        consumeArmed: @escaping (Set<UUID>) -> Void
    ) {
        self.resolveSources = resolveSources
        self.answerAboutScreen = answerAboutScreen
        self.sendFunctionCallOutput = sendFunctionCallOutput
        self.sendResponseCreate = sendResponseCreate
        self.consumeArmed = consumeArmed
    }

    // MARK: - Public

    /// Advance the turn token (barge-in / turn-end). Any in-flight vision call
    /// whose dispatch token no longer matches will be dropped silently.
    public func advanceTurnToken() {
        turnToken += 1
    }

    /// Handle an `.analyzeScreen` tool call decision from `VoiceTurnController`.
    ///
    /// - Parameters:
    ///   - decision: Must be `.analyzeScreen(_)`.
    ///   - callId: The Realtime tool call ID for the `function_call_output`.
    public func handle(_ decision: ToolCallDecision, callId: String) async {
        guard case .analyzeScreen(let args) = decision else { return }

        // Snapshot token and resolve sources at dispatch time.
        let dispatchToken = turnToken
        let resolved = resolveSources()
        let resolvedArmedIds = Set(resolved.armed.map(\.id))

        // All sources passed to the vision call (armed + current if present).
        var allAppshots = resolved.armed
        if let current = resolved.current { allAppshots.append(current) }

        do {
            let answer = try await answerAboutScreen(args.question, allAppshots)

            // Stale check: if the token was advanced during the async call, drop.
            guard turnToken == dispatchToken else {
                // Barge-in occurred — drop silently, no fco, no rc, no consume.
                return
            }

            // Success: emit fco then rc, then consume resolve-time armed ids.
            sendFunctionCallOutput(callId, answer)
            sendResponseCreate()
            if !resolvedArmedIds.isEmpty {
                consumeArmed(resolvedArmedIds)
            }

        } catch {
            // Active error: the call is still current — must emit error-shaped fco
            // + rc to unblock the Realtime turn. Never consume on error.
            //
            // Stale check still applies: a barge-in before an error is still stale.
            guard turnToken == dispatchToken else { return }

            let errorFco = buildErrorFco(reason: error.localizedDescription)
            sendFunctionCallOutput(callId, errorFco)
            sendResponseCreate()
            // Never consume on error.
        }
    }

    // MARK: - Private

    /// Build an error-shaped `function_call_output` JSON string.
    ///
    /// Shape: `{"kind":"screen_vision_error","error":"<short reason>"}`.
    /// This is the contract with the Realtime model: it must see a valid
    /// fco to unblock the in-flight tool call.
    private func buildErrorFco(reason: String) -> String {
        // Sanitize: truncate to a safe length to avoid Realtime payload limits.
        let safeReason = String(reason.prefix(256))
        let escaped = safeReason
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "{\"kind\":\"screen_vision_error\",\"error\":\"\(escaped)\"}"
    }
}
