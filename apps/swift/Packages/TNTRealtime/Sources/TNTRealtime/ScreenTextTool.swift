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

/// Factory for the M4a Tier-1 screen text tool.
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
}
