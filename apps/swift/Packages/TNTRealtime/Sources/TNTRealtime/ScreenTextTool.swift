// ScreenTextTool — the Tier-1 Realtime screen tool for M4a text-tier Appshots.
//
// Per ADR-0006 (amendment, 2026-06-11): the original single `look_at_screen`
// tool is superseded by a two-tier pair. Tier 1 (`read_screen_text`) returns
// a structured Window-Text snapshot directly as the `function_call_output` —
// no Cognitive Engine call, no image involved. Image bytes still never ride
// the Realtime WebSocket — that firewall is unchanged.
//
// Also provides `armedAppshotsContextNote(count:)`, a pure string builder
// that injects "N appshot(s) attached" into the session context so the
// model knows context is available even before the user says "look at this."
// This note is injected at session-update time when Appshots are armed.
//
// Both are pure values — no app-state reads, no capture — so they are
// golden-testable without any Cocoa or TCC dependencies.

import Foundation

// MARK: - Tier-1 screen tool

/// Factory for the M4a Tier-1 screen text tool and the M4b Tier-2 vision tool.
public enum ScreenTextTool {

    /// The Realtime function tool that returns a Window-Text snapshot for a Voice Turn.
    ///
    /// When the model calls `read_screen_text`, TNT:
    /// 1. Resolves the source: armed Appshots from the Capture Set if present;
    ///    otherwise grabs the frontmost window's text via the Accessibility API.
    /// 2. Returns a structured `ScreenTextSnapshot` JSON string directly as the
    ///    `function_call_output` — no Cognitive Engine call.
    ///
    /// The `question` parameter is required (the model passes the user's ask
    /// verbatim), same pattern as `compose_agent_prompt.raw_transcript`.
    ///
    /// Naming: per ADR-0006 amendment, `read_screen_text` is the Tier-1 tool;
    /// `analyze_screen` (M4b) is Tier-2 and registered separately when vision ships.
    public static let tool: RealtimeTool = RealtimeTool(
        name: "read_screen_text",
        description: "Answer a question about what's on the user's screen from the window's text. Use when the user asks about what's on screen (\"look at this\", \"what does this say\", \"what's this error\") and text is likely sufficient. The output is a structured Window-Text snapshot. Some apps (image-only windows, Google Docs) may expose little or no text — the snapshot will say so.",
        parameters: JSONValue.schema(
            type: "object",
            properties: [
                "question": .object([
                    "type": .string("string"),
                    "description": .string("The user's question about what's on screen, passed verbatim (e.g. \"what's causing this error?\", \"summarize this document\").")
                ])
            ],
            required: ["question"],
            additionalProperties: false
        )
    )

    // MARK: - Tier-2 vision tool (M4b)

    /// The Realtime function tool that routes a screen question through the
    /// vision-capable Cognitive Engine (M4b ESCALATION tier).
    ///
    /// The model must only call `analyze_screen` when `read_screen_text`
    /// returned an empty/sparse/insufficient snapshot for the question.
    /// This triggers a vision-model call (image + Window Text) via the
    /// Cognitive Engine — more expensive and slower than Tier 1.
    ///
    /// Per ADR-0006 (amendment): composable registration — this tool is
    /// appended AFTER `read_screen_text` in `withVisionTools()` so the
    /// model sees Tier 1 first. Both tools are registered only when
    /// `visionEnabled == true` in `desiredSessionConfig`.
    public static let analyzeScreenTool: RealtimeTool = RealtimeTool(
        name: "analyze_screen",
        description: "ESCALATION tier — call this ONLY when read_screen_text's snapshot was empty, sparse, or insufficient to answer the question and the user needs a vision-capable answer. Routes image + Window Text through the vision Cognitive Engine. More expensive than read_screen_text.",
        parameters: JSONValue.schema(
            type: "object",
            properties: [
                "question": .object([
                    "type": .string("string"),
                    "description": .string("The user's question about what's on screen, passed verbatim.")
                ])
            ],
            required: ["question"],
            additionalProperties: false
        )
    )

}

// MARK: - Armed appshots context note

/// Build the session context note that tells the model armed Appshots are
/// available. Injected into the session instructions when the Appshot Hotkey
/// has been pressed (i.e. `appshots.count > 0`). For zero Appshots, returns
/// an empty string — no note is needed.
///
/// This is a pure string builder: golden-testable, no app state involved.
///
/// - Parameter count: the number of armed Appshots in the current Capture Set.
/// - Returns: a short instruction string to append to the session instructions,
///   or an empty string when `count == 0`.
public func armedAppshotsContextNote(count: Int) -> String {
    guard count > 0 else { return "" }
    let plural = count == 1 ? "appshot" : "appshots"
    return "The user has \(count) \(plural) attached from the Appshot Hotkey. Call read_screen_text to view them."
}

// MARK: - SessionUpdate.Body extension

extension SessionUpdate.Body {
    /// Returns a new `Body` with the M4a screen text tool appended to any existing
    /// tools. Chain with `withRewriteTools()` at the composition root, e.g.
    /// `SessionUpdate.bilingualV0().session.withRewriteTools().withScreenTools()`.
    /// `toolChoice` defaults to `"auto"`.
    public func withScreenTools(toolChoice: String = "auto") -> SessionUpdate.Body {
        appendingTools([ScreenTextTool.tool], toolChoice: toolChoice)
    }

    /// Returns a new `Body` with the M4b `analyze_screen` vision tool appended
    /// AFTER `read_screen_text`. Per ADR-0006: composable registration — callers
    /// first call `withScreenTools()` then chain this to add the escalation tier.
    ///
    /// Only call this when `visionEnabled == true` (i.e. Screen Recording TCC
    /// has been granted). The model escalates from Tier 1 → Tier 2 based on
    /// snapshot quality, never the other way around.
    public func withVisionTools(toolChoice: String = "auto") -> SessionUpdate.Body {
        appendingTools([ScreenTextTool.analyzeScreenTool], toolChoice: toolChoice)
    }
}
