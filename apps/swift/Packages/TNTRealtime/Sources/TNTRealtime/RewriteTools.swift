// RewriteTools — the two Realtime session tool schemas for the M1
// Rewrite flow. Schema-only: no handler wiring (that's in the M1
// tool-dispatch issue). The value here is a stable, golden-tested
// contract the handler wiring can build against.
//
// Tool 1 — compose_agent_prompt(target, intent, raw_transcript)
//   Called by the Realtime model when it wants to hand a Voice Turn
//   transcript to the Cognitive Engine and speak back the cleaned
//   prompt for confirmation. The app routes it to CognitiveEngine.compose
//   and re-injects the result via function_call_output.
//
// Tool 2 — deliver_prompt (NO payload parameters)
//   A confirmation signal. The model calls it when the user affirms
//   (bilingual yes-detection — "yes" / "对" / "好" / "go ahead" — is
//   the Realtime model's job). The app delivers the already-stored
//   pending Rewrite; no text is injected by the model. This design
//   (per the counsel review in issue #47 body) prevents prompt injection:
//   the model cannot vary or exfiltrate the delivered content.
//
// Both tools ride the function_call → function_call_output → response.create
// path from issue #30.

import Foundation

/// Factory for the M1 Rewrite tool definitions. Each method returns a
/// `RealtimeTool` that can be included in `SessionUpdate.Body.tools`.
/// A convenience extension on `SessionUpdate.Body` composes them with
/// any other tools (e.g. the M4 vision tool, M5 executor tools).
public enum RewriteTools {

    // MARK: - compose_agent_prompt

    /// Tool the Realtime model calls to request a **Rewrite** of the
    /// current Voice Turn transcript. The app routes this call to
    /// `CognitiveEngine.compose` and re-injects the cleaned prompt so
    /// the model can speak it back and ask for confirmation.
    ///
    /// Parameters (all required):
    /// - `target` (string): stable key of the target Worker Agent
    ///   (e.g. `"claude-code"`, `"cursor"`).
    /// - `intent` (string): one-line intent distilled from the transcript.
    /// - `raw_transcript` (string): the raw, messy bilingual user speech.
    public static let composeAgentPrompt: RealtimeTool = RealtimeTool(
        name: "compose_agent_prompt",
        description: "Rewrite a messy Voice Turn transcript into a clean Worker Agent prompt. Call this when the user finishes speaking and wants to send an instruction to a Worker Agent (Claude Code, Cursor, etc.). Returns the cleaned prompt for confirmation.",
        parameters: JSONValue.schema(
            type: "object",
            properties: [
                "target": .object([
                    "type": .string("string"),
                    "description": .string("Stable key of the target Worker Agent, e.g. \"claude-code\", \"cursor\".")
                ]),
                "intent": .object([
                    "type": .string("string"),
                    "description": .string("One-line intent distilled from the transcript.")
                ]),
                "raw_transcript": .object([
                    "type": .string("string"),
                    "description": .string("The full raw bilingual Voice Turn transcript the user spoke.")
                ])
            ],
            required: ["target", "intent", "raw_transcript"],
            additionalProperties: false
        )
    )

    // MARK: - deliver_prompt

    /// Tool the Realtime model calls when the user affirms the pending Rewrite
    /// ("yes" / "对" / "好" / "go ahead" — the model owns bilingual detection).
    ///
    /// This tool carries **no payload parameters** by design. The app delivers
    /// the already-stored pending Rewrite — the model does not inject text.
    /// This is the structural firewall against prompt injection and exfiltration:
    /// whatever the app delivers was the cleaned prompt from `compose_agent_prompt`,
    /// not model-generated content at confirm time.
    ///
    /// Calling this tool without a preceding `compose_agent_prompt` in the same
    /// turn (i.e. no pending Rewrite) is a no-op — the app silently ignores it.
    public static let deliverPrompt: RealtimeTool = RealtimeTool(
        name: "deliver_prompt",
        description: "Deliver the pending Rewrite to the target Worker Agent. Call this ONLY when the user explicitly affirms the composed prompt (\"yes\", \"对\", \"好\", \"go ahead\", or equivalent). Do NOT call this if the user declines or asks to change the prompt.",
        parameters: JSONValue.schema(
            type: "object",
            properties: [:],
            required: [],
            additionalProperties: false
        )
    )

    // MARK: - Convenience

    /// Both M1 Rewrite tools as an array, ready to include in
    /// `SessionUpdate.Body.tools`. Order: compose first (the model
    /// needs to call it before deliver).
    public static let all: [RealtimeTool] = [composeAgentPrompt, deliverPrompt]
}

// MARK: - SessionUpdate.Body extension

extension SessionUpdate.Body {
    /// Returns a new `Body` with the M1 Rewrite tools appended to any
    /// existing tools. `toolChoice` defaults to `"auto"` — the model
    /// decides when to call compose / deliver. Pass a custom `toolChoice`
    /// to override (e.g. `"none"` during a pure-audio M0 mode).
    public func withRewriteTools(toolChoice: String = "auto") -> SessionUpdate.Body {
        var copy = self
        copy.tools = (copy.tools ?? []) + RewriteTools.all
        copy.toolChoice = toolChoice
        return copy
    }
}
