// ToolCallDispatch — pure Realtime tool-call decode + classify (issue #78;
// extended for read_screen_text in issue #105; extended for analyze_screen
// in issue #122 M4b).
//
// Converts a Realtime server event's raw (name, argumentsJSON) pair into a
// typed `ToolCallDecision` so `VoiceTurnController` (the app-target glue
// layer) never does JSON decoding inline and remains untestable.
//
// Design constraints:
// - Takes String primitives only — matching
//   `RealtimeServerEvent.functionCallArgumentsDone(callId:name:argumentsJSON:)`
//   associated values — so TNTRealtime is never imported here.
// - Decode fails **soft**: argumentsJSON is model-generated and may not conform,
//   so a malformed/missing-field payload must not crash the caller.
// - read_screen_text malformed → still `.readScreen` with nil question (the
//   turn must proceed regardless; question is best-effort).
// - analyze_screen malformed → still `.analyzeScreen` with nil question (same
//   soft-fail policy mirrors read_screen_text).
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

/// Decoded arguments for the `read_screen_text` Tier-1 tool call.
///
/// The `question` field is required in the schema but the model may emit
/// a malformed payload. Soft-decode: a malformed JSON still produces a
/// `ReadScreenArgs` with `nil` question so the turn can proceed.
public struct ReadScreenArgs: Equatable, Sendable {

    /// The user's question passed verbatim from the model. `nil` if the
    /// model emitted malformed JSON (the turn proceeds anyway).
    public let question: String?

    public init(question: String?) {
        self.question = question
    }

    // MARK: - Soft decode

    /// Soft-decode from raw JSON. On any failure, returns `ReadScreenArgs(question: nil)`
    /// so the screen tool still fires (question is best-effort).
    public static func decode(from argumentsJSON: String) -> ReadScreenArgs {
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let question = obj["question"] as? String else {
            return ReadScreenArgs(question: nil)
        }
        return ReadScreenArgs(question: question)
    }
}

/// Decoded arguments for the `analyze_screen` Tier-2 vision tool call (M4b).
///
/// Mirrors `ReadScreenArgs`: `question` is required in the schema but soft-
/// decoded so a malformed model payload still yields `.analyzeScreen` with
/// a `nil` question — the turn must proceed regardless.
public struct AnalyzeScreenArgs: Equatable, Sendable {

    /// The user's question passed verbatim from the model. `nil` if the
    /// model emitted malformed JSON (the vision call proceeds anyway).
    public let question: String?

    public init(question: String?) {
        self.question = question
    }

    // MARK: - Soft decode

    /// Soft-decode from raw JSON. On any failure, returns `AnalyzeScreenArgs(question: nil)`
    /// so the vision tool still fires (question is best-effort).
    public static func decode(from argumentsJSON: String) -> AnalyzeScreenArgs {
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let question = obj["question"] as? String else {
            return AnalyzeScreenArgs(question: nil)
        }
        return AnalyzeScreenArgs(question: question)
    }
}

// MARK: - Decision

/// The typed outcome of dispatching a Realtime tool-call name.
public enum ToolCallDecision: Equatable, Sendable {
    /// `compose_agent_prompt` — run the Cognitive Engine Rewrite path.
    case compose(ComposeAgentPromptArgs)
    /// `deliver_prompt` — deliver the pending Rewrite to the Worker Agent.
    case deliver
    /// `read_screen_text` — run the Tier-1 screen text snapshot path.
    case readScreen(ReadScreenArgs)
    /// `analyze_screen` — run the M4b Tier-2 vision path via the Cognitive Engine.
    case analyzeScreen(AnalyzeScreenArgs)
    /// Any other tool name (or a `compose_agent_prompt` with undecodable args).
    case ignore
}

// MARK: - Classifier

/// Classify a Realtime function-call event into a `ToolCallDecision`.
///
/// - Parameters:
///   - name: The tool name from the server event (e.g. `"compose_agent_prompt"`).
///   - argumentsJSON: The raw arguments JSON string from the server event.
/// - Returns: A typed decision; never throws — malformed payloads produce `.ignore`
///   (or for screen tools, the appropriate `.readScreen`/`.analyzeScreen` with nil question).
public func classifyToolCall(name: String, argumentsJSON: String) -> ToolCallDecision {
    switch name {
    case "compose_agent_prompt":
        guard let args = ComposeAgentPromptArgs.decode(from: argumentsJSON) else {
            return .ignore
        }
        return .compose(args)
    case "deliver_prompt":
        return .deliver
    case "read_screen_text":
        // Always returns .readScreen — even on malformed JSON. The question may be nil.
        return .readScreen(ReadScreenArgs.decode(from: argumentsJSON))
    case "analyze_screen":
        // Always returns .analyzeScreen — even on malformed JSON. The question may be nil.
        // Mirrors the read_screen_text soft-fail policy so an active tool call is
        // never left unanswered, which would stall the Realtime turn permanently.
        return .analyzeScreen(AnalyzeScreenArgs.decode(from: argumentsJSON))
    default:
        return .ignore
    }
}
