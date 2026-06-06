// ToolCallDispatch — pure Realtime tool-call decode + classify (issue #78).
//
// Converts a Realtime server event's raw (name, argumentsJSON) pair into a
// typed `ToolCallDecision` so `VoiceTurnController` (the app-target glue
// layer) never does JSON decoding inline and remains untestable.
//
// Design constraints (issue #78):
// - Takes String primitives only — matching
//   `RealtimeServerEvent.functionCallArgumentsDone(callId:name:argumentsJSON:)`
//   associated values — so TNTRealtime is never imported here.
// - Decode fails **soft**: argumentsJSON is model-generated and may not conform,
//   so a malformed/missing-field payload must not crash the caller.
// - Imports only TNTCore (enforced by the Package.swift dependency graph).

import Foundation
import TNTCore

// MARK: - Args

/// Decoded arguments for the `compose_agent_prompt` Realtime tool call.
///
/// The Realtime model emits these as a JSON string; `decode(from:)` does the
/// safe, soft decode so the caller never needs a try/catch at the tool-dispatch
/// site.
public struct ComposeAgentPromptArgs: Decodable, Equatable, Sendable {

    /// The target Worker Agent key, e.g. `"claude-code"`, `"cursor"`.
    public let target: String

    /// The cleaned intent the Cognitive Engine should use for the Rewrite.
    public let intent: String

    /// The raw bilingual transcript from the Voice Turn — optional because
    /// the model may omit it on very short turns.
    public let rawTranscript: String?

    private enum CodingKeys: String, CodingKey {
        case target
        case intent
        case rawTranscript = "raw_transcript"
    }

    // MARK: - Soft decode

    /// Decode from a raw JSON string produced by the Realtime model.
    ///
    /// Returns `nil` on any failure — malformed JSON, missing required fields —
    /// so the caller can safely fall through to `.ignore` without a try/catch.
    public static func decode(from argumentsJSON: String) -> ComposeAgentPromptArgs? {
        guard let data = argumentsJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ComposeAgentPromptArgs.self, from: data)
    }
}

// MARK: - Decision

/// The typed outcome of dispatching a Realtime tool-call name.
public enum ToolCallDecision: Equatable, Sendable {
    /// `compose_agent_prompt` — run the Cognitive Engine Rewrite path.
    case compose(ComposeAgentPromptArgs)
    /// `deliver_prompt` — deliver the pending Rewrite to the Worker Agent.
    case deliver
    /// Any other tool name (or a `compose_agent_prompt` with undecodable args).
    case ignore
}

// MARK: - Classifier

/// Classify a Realtime function-call event into a `ToolCallDecision`.
///
/// - Parameters:
///   - name: The tool name from the server event (e.g. `"compose_agent_prompt"`).
///   - argumentsJSON: The raw arguments JSON string from the server event.
/// - Returns: A typed decision; never throws — malformed payloads produce `.ignore`.
public func classifyToolCall(name: String, argumentsJSON: String) -> ToolCallDecision {
    switch name {
    case "compose_agent_prompt":
        guard let args = ComposeAgentPromptArgs.decode(from: argumentsJSON) else {
            return .ignore
        }
        return .compose(args)
    case "deliver_prompt":
        return .deliver
    default:
        return .ignore
    }
}
