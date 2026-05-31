// AppShotVisionTool — the single Realtime vision tool for M4 Appshots.
//
// Per ADR-0006 (Appshot vision routing) and CONTEXT.md: both Appshot
// triggers (hotkey-armed path and voice-pull "look at this") converge
// on ONE Realtime function tool. When the model calls it, TNT resolves
// the source — armed Appshots if present, else a fresh frontmost-window
// grab — and routes the image + Window Text to the Cognitive Engine.
// The Cognitive Engine's answer is re-injected via function_call_output
// (#30) so the Realtime model speaks it in one continuous voice.
//
// Also provides `armedAppshotsContextNote(count:)`, a pure string builder
// that injects "N appshot(s) attached" into the session context so the
// model knows vision is available even before the user says "look at this."
// This note is injected at session-update time when Appshots are armed.
//
// Both are pure values — no app-state reads, no capture — so they are
// golden-testable without any Cocoa or TCC dependencies.

import Foundation

// MARK: - Vision tool

/// Factory for the single M4 Appshot vision tool.
public enum AppShotVisionTool {

    /// The single Realtime function tool that activates vision for a Voice Turn.
    ///
    /// When the model calls `look_at_screen`, TNT:
    /// 1. Resolves the source: armed Appshots from the Capture Set if present;
    ///    otherwise grabs the frontmost window fresh.
    /// 2. Routes image + Window Text to the Cognitive Engine (via
    ///    `LocalOpenAIEngine`'s vision route — see ADR-0006).
    /// 3. Re-injects the answer as `function_call_output` (#30) so the
    ///    Realtime model speaks it.
    ///
    /// Parameters: one optional `focus` hint the user can include ("what's
    /// the error?", "summarize the diff"). The handler uses it as context
    /// for the Cognitive Engine's vision request. Omit for a broad look.
    ///
    /// Naming: `look_at_screen` is deliberately distinct from the
    /// Realtime voice "look at this" phrase — the model decides when
    /// to call the tool based on conversational context.
    public static let tool: RealtimeTool = RealtimeTool(
        name: "look_at_screen",
        description: "Capture the frontmost window (image + text) and answer a question about it. Use when the user says \"look at this\", \"what's on screen\", \"can you see\", or similar. Armed Appshots (captured via the hotkey) take priority over a fresh grab.",
        parameters: JSONValue.schema(
            type: "object",
            properties: [
                "focus": .object([
                    "type": .string("string"),
                    "description": .string("Optional one-line question or focus hint for the vision analysis, e.g. \"what's causing this error?\" or \"summarize the diff.\"")
                ])
            ],
            required: [],
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
    return "The user has \(count) \(plural) attached from the Appshot Hotkey. Call look_at_screen to view them."
}

// MARK: - SessionUpdate.Body extension

extension SessionUpdate.Body {
    /// Returns a new `Body` with the M4 vision tool appended to any existing
    /// tools. Chain with `withRewriteTools()` at the composition root, e.g.
    /// `SessionUpdate.bilingualV0().session.withRewriteTools().withVisionTool()`.
    /// `toolChoice` defaults to `"auto"`.
    public func withVisionTool(toolChoice: String = "auto") -> SessionUpdate.Body {
        appendingTools([AppShotVisionTool.tool], toolChoice: toolChoice)
    }
}
