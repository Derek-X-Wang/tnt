// RewritePromptBuilder — pure function that assembles the OpenAI
// chat/completions request messages for a Rewrite call. No network,
// no state — deterministic input → deterministic output — so the
// output is golden-testable without any network or mock.
//
// Per CONTEXT.md (Rewrite): messy bilingual rambling → clean Worker
// Agent prompt. Per CONTEXT.md (bilingual scope): English is the
// default output for Worker Agents; technical terms (function names,
// library names, code) stay verbatim.
//
// Structure of the messages array:
//   1. system — Rewrite rules (bilingual-aware, terse, no preamble)
//   2. few-shot examples — one pure-en, one pure-zh, one code-switch
//      (each is a user/assistant pair showing raw → cleaned)
//   3. user — the current turn's raw transcript + Capture Set bullets

import Foundation
import TNTCore

// MARK: - Message types

/// A single message in the OpenAI chat completions request.
public struct ChatMessage: Codable, Sendable, Equatable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

// MARK: - Prompt builder

public enum RewritePromptBuilder {

    // MARK: - System prompt

    /// The Rewrite system prompt. Lives in code so every change is
    /// a reviewed PR (same rationale as `RealtimePrompts`).
    public static let systemPrompt: String = """
    You are the Rewrite engine for TNT, a voice-first Personal Master Agent. \
    Your single job: transform a messy, bilingual, spoken Voice Turn transcript \
    into one clean, concise paragraph addressed to a Worker Agent (Claude Code, \
    Cursor, etc.).

    Rules:
    1. Output a SINGLE clean English paragraph. No preamble, no explanation, \
       no markdown fences, no "Here is your prompt:".
    2. Preserve ALL technical terms verbatim — function names, library names, \
       file paths, CLI commands, variable names. Never translate or de-hyphenate \
       them (e.g. `rate-limit` stays `rate-limit`, not "rate limit" or "速率限制").
    3. The User may speak English, Mandarin, or a mix inside one turn. Always \
       produce English output for the Worker Agent unless the User explicitly \
       asks for a different language.
    4. Distill intent and remove rambling, filler words, false starts, and \
       repetition. Keep actionable specifics.
    5. Never invent details not present in the transcript.
    """

    // MARK: - Few-shot examples

    /// Few-shot bilingual examples included in every Rewrite request.
    /// These are user/assistant pairs showing raw Voice Turn → cleaned
    /// Worker Agent prompt. They demonstrate the code-switch handling
    /// and technical-term preservation rules.
    static let fewShotExamples: [ChatMessage] = [
        // Pure English example
        ChatMessage(role: "user", content: """
        Target: Claude Code
        Raw transcript: "um, I want you to add, uh, a unit test to the \
        rate-limit middleware. The test should mock the bucket and cover \
        three timeout scenarios, like, the normal one, the edge case \
        where it's exactly at the limit, and then when it exceeds."
        Context: app=Cursor, project=tnt, selection=(none)
        """),
        ChatMessage(role: "assistant", content: """
        Add a unit test to the rate-limit middleware that mocks the bucket \
        and covers three timeout scenarios: normal operation, exactly-at-limit \
        edge case, and exceeds-limit.
        """),

        // Pure Mandarin example
        ChatMessage(role: "user", content: """
        Target: Claude Code
        Raw transcript: "帮我在 authentication 模块里加一个 refresh token 的功能，\
        就是用户 token 快过期的时候，自动续期，不用重新登录。"
        Context: app=Cursor, project=backend, selection=(none)
        """),
        ChatMessage(role: "assistant", content: """
        Add a refresh-token feature to the authentication module: automatically \
        renew the token when it is close to expiry so the user does not need to \
        log in again.
        """),

        // Code-switch example (the acceptance criterion case)
        ChatMessage(role: "user", content: """
        Target: Claude Code
        Raw transcript: "这个 function should rate-limit 每个 IP，max 10次 per second，\
        用 sliding window 算法，然后如果超了就返回 429。"
        Context: app=Cursor, project=tnt, selection=(none)
        """),
        ChatMessage(role: "assistant", content: """
        In the rate-limit function, enforce a per-IP limit of 10 requests per \
        second using a sliding-window algorithm; return 429 when the limit is \
        exceeded.
        """),
    ]

    // MARK: - Public API

    /// Build the `messages` array for an OpenAI chat/completions Rewrite
    /// call. The output is deterministic — same inputs produce the same
    /// messages — making it suitable for golden tests without network.
    ///
    /// - Parameters:
    ///   - target: The Worker Agent the Rewrite addresses.
    ///   - intent: One-line intent (from the Realtime tool's argument).
    ///   - raw: Raw messy Voice Turn transcript.
    ///   - capture: Capture Set attached to the Voice Turn.
    /// - Returns: The messages array ready to send in an OpenAI
    ///   `chat/completions` request body.
    public static func buildMessages(
        target: AgentRef,
        intent: String,
        raw: String,
        capture: CaptureSet
    ) -> [ChatMessage] {
        var messages: [ChatMessage] = []

        // 1. System prompt
        messages.append(ChatMessage(role: "system", content: systemPrompt))

        // 2. Few-shot examples
        messages.append(contentsOf: fewShotExamples)

        // 3. User message for this turn
        messages.append(ChatMessage(
            role: "user",
            content: userMessage(target: target, intent: intent, raw: raw, capture: capture)
        ))

        return messages
    }

    // MARK: - Private helpers

    static func userMessage(
        target: AgentRef,
        intent: String,
        raw: String,
        capture: CaptureSet
    ) -> String {
        var lines: [String] = []
        lines.append("Target: \(target.displayName ?? target.key)")
        lines.append("Intent: \(intent)")
        lines.append("Raw transcript: \"\(raw)\"")

        // Capture Set bullets (omit if empty to keep the prompt short).
        if !capture.isEmpty {
            lines.append("Context:")
            if let app = capture.appName { lines.append("  app=\(app)") }
            if let title = capture.windowTitle { lines.append("  window=\(title)") }
            if let selection = capture.selectedText { lines.append("  selection=\(selection)") }
            if let project = capture.project { lines.append("  project=\(project.name)") }
        } else {
            lines.append("Context: (none)")
        }

        return lines.joined(separator: "\n")
    }
}
