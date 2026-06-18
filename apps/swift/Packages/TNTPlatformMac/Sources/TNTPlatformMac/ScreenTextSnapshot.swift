// ScreenTextSnapshot — Tier-1 `function_call_output` payload builder for M4a/M4b.
//
// Turns `(question, armed: [Appshot], current: Appshot?, visionAvailable, now)`
// into the JSON string the Realtime model reads as the `read_screen_text`
// tool's output. Mixed mode (#119): armed and current sources side by side,
// labeled, with per-source capture age.
//
// Per ADR-0006 (amendment): Tier 1 returns Window-Text snapshots directly —
// no Cognitive Engine call, no image bytes. This builder is the single source
// of truth for that JSON shape.
//
// Design constraints (issue #100 + #124):
// - Pure: imports Foundation + TNTCore only; no AppKit, no ApplicationServices.
// - Deterministic output via explicit `Encodable` conformance (stable key order).
// - `visionAvailable: false` in M4a (no escalation hint; M4b flips to true).
// - Total text budget ~8,000 chars across sources; head+tail truncation.
// - Empty/sparse text is a valid snapshot — never an error.
// - Issue #124 (M4b): `recommendedNextTool: String?` emitted via `encodeIfPresent`
//   so `visionAvailable: false` output is byte-identical to existing goldens
//   (field simply absent). Set to "analyze_screen" when visionAvailable == true
//   AND every source is .empty or .sparse (or there are zero sources).

import Foundation
import TNTCore

// MARK: - Source kind

/// Whether the Appshot came from the arm queue or the fresh grab of the
/// current frontmost window. Mixed mode (#119): one snapshot can carry both,
/// each source labeled, so the model knows what is on screen NOW versus what
/// the user deliberately captured earlier.
public enum ScreenTextSourceKind: String, Encodable, Equatable, Sendable {
    case armedAppshot = "armed_appshot"
    case freshGrab    = "fresh_grab"
}

// MARK: - Text quality

/// Qualitative assessment of the Window Text returned.
/// Used by the model to decide whether to escalate to Tier-2 vision.
public enum TextQuality: String, Encodable, Equatable, Sendable {
    case ok     = "ok"
    case sparse = "sparse"
    case empty  = "empty"
}

// MARK: - Source entry

/// One source entry in the `ScreenTextSnapshot.sources` array.
/// Each represents one Appshot (armed or voice-pulled) that contributed text.
public struct ScreenTextSnapshotSource: Encodable, Equatable, Sendable {

    public let appName: String
    public let windowTitle: String
    public let source: ScreenTextSourceKind
    /// Seconds between capture and snapshot build (#119) — lets the model
    /// flag staleness ("from your Arc capture 4 minutes ago"). Nil when the
    /// Appshot carries no `capturedAt` (pre-#119 payloads).
    public let capturedSecondsAgo: Int?
    public let text: String
    public let originalCharCount: Int
    public let returnedCharCount: Int
    public let truncated: Bool
    public let textQuality: TextQuality

    private enum CodingKeys: String, CodingKey {
        case appName        = "appName"
        case windowTitle    = "windowTitle"
        case source
        case capturedSecondsAgo
        case text
        case originalCharCount
        case returnedCharCount
        case truncated
        case textQuality
    }

    public init(
        appName: String,
        windowTitle: String,
        source: ScreenTextSourceKind,
        capturedSecondsAgo: Int?,
        text: String,
        originalCharCount: Int,
        returnedCharCount: Int,
        truncated: Bool,
        textQuality: TextQuality
    ) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.source = source
        self.capturedSecondsAgo = capturedSecondsAgo
        self.text = text
        self.originalCharCount = originalCharCount
        self.returnedCharCount = returnedCharCount
        self.truncated = truncated
        self.textQuality = textQuality
    }
}

// MARK: - Snapshot

/// The structured payload returned as the Tier-1 `function_call_output`.
///
/// Deterministic Encodable: keys are emitted in a fixed order so the output
/// is byte-identical for identical inputs (golden-testable).
///
/// `recommendedNextTool` is emitted only when non-nil (via `encodeIfPresent`)
/// so the `visionAvailable: false` output path stays byte-identical to
/// existing goldens — the field is simply absent in M4a output.
public struct ScreenTextSnapshot: Encodable, Equatable, Sendable {

    public let kind: String
    public let version: Int
    public let question: String?
    /// Escalation hint (issue #124): set to `"analyze_screen"` when
    /// `visionAvailable == true` and every source is `.empty` or `.sparse`
    /// (or there are zero sources). Nil and omitted from JSON otherwise.
    public let recommendedNextTool: String?
    public let sources: [ScreenTextSnapshotSource]
    public let fullVisionAvailable: Bool
    public let instruction: String

    private enum CodingKeys: String, CodingKey {
        case kind
        case version
        case question
        case recommendedNextTool
        case sources
        case fullVisionAvailable
        case instruction
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(question, forKey: .question)
        try container.encodeIfPresent(recommendedNextTool, forKey: .recommendedNextTool)
        try container.encode(sources, forKey: .sources)
        try container.encode(fullVisionAvailable, forKey: .fullVisionAvailable)
        try container.encode(instruction, forKey: .instruction)
    }

    public init(
        question: String?,
        recommendedNextTool: String?,
        sources: [ScreenTextSnapshotSource],
        fullVisionAvailable: Bool,
        instruction: String
    ) {
        self.kind = "screen_text_snapshot"
        // v2 (#119): mixed armed+current sources, per-source kind labels,
        // capturedSecondsAgo, name-your-source instruction.
        // #124: adds optional recommendedNextTool escalation hint (same shape family).
        self.version = 2
        self.question = question
        self.recommendedNextTool = recommendedNextTool
        self.sources = sources
        self.fullVisionAvailable = fullVisionAvailable
        self.instruction = instruction
    }

    // MARK: - JSON builder

    /// Encode to a JSON string suitable for `function_call_output`.
    /// Uses a deterministic encoder (sortedKeys) for golden testability.
    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Builder

/// Builds a `ScreenTextSnapshot` from a list of Appshots and a question.
///
/// Total text budget: 8,000 chars distributed across sources. Each source
/// uses head+tail truncation (preserving the start and end of the text with
/// an elision marker in the middle) so context-at-top and errors-at-bottom
/// are both preserved.
///
/// A fully-elided source still appears in `sources` with `returnedCharCount: 0`
/// — no source is silently dropped.
public struct ScreenTextSnapshotBuilder {

    /// Total character budget across all sources (head+tail combined).
    public static let totalBudget: Int = 8_000

    /// Minimum chars reserved per source for the head segment.
    /// Below this, a source gets `returnedCharCount: 0` but still appears.
    public static let minHeadChars: Int = 20

    /// The elision marker inserted between head and tail when truncated.
    public static let elisionMarker: String = "\n…[truncated]…\n"

    /// Build a snapshot from the resolved sources and an optional question.
    ///
    /// Mixed mode (#119): armed Appshots come first (deliberate user intent,
    /// arm order), the fresh `current` grab last, each labeled with its kind
    /// and capture age. The budget is distributed across ALL sources.
    ///
    /// - Parameters:
    ///   - question: The user's question from the tool call arguments.
    ///   - armed: Armed Appshots (arm order; already deduped by the resolver).
    ///   - current: Fresh grab of the current frontmost window, if captured.
    ///   - visionAvailable: Whether `analyze_screen` is registered. M4a passes `false`;
    ///     M4b flips this to `true` and the builder emits the escalation hint.
    ///   - now: Reference instant for `capturedSecondsAgo` (injected — keeps
    ///     the builder pure and golden-testable).
    /// - Returns: A `ScreenTextSnapshot` ready for `jsonString()`.
    public static func build(
        question: String?,
        armed: [Appshot],
        current: Appshot?,
        visionAvailable: Bool,
        now: Date
    ) -> ScreenTextSnapshot {
        let entries: [(Appshot, ScreenTextSourceKind)] =
            armed.map { ($0, .armedAppshot) } + (current.map { [($0, .freshGrab)] } ?? [])
        let sources = buildSources(entries: entries, now: now)
        let instruction = buildInstruction(visionAvailable: visionAvailable)
        // Issue #124: emit escalation hint only when visionAvailable and every
        // source is empty/sparse (or there are no sources at all). The field is
        // omitted from JSON when nil, so M4a output stays byte-identical.
        let recommendedNextTool = buildRecommendedNextTool(
            visionAvailable: visionAvailable,
            sources: sources
        )
        return ScreenTextSnapshot(
            question: question,
            recommendedNextTool: recommendedNextTool,
            sources: sources,
            fullVisionAvailable: visionAvailable,
            instruction: instruction
        )
    }

    // MARK: - Private helpers

    private static func buildSources(
        entries: [(Appshot, ScreenTextSourceKind)],
        now: Date
    ) -> [ScreenTextSnapshotSource] {
        guard !entries.isEmpty else { return [] }

        // Distribute the budget evenly across sources; each source gets at least
        // one slot in the output even if the budget is fully exhausted.
        let budgetPerSource = max(1, totalBudget / entries.count)

        return entries.map { appshot, kind in
            buildSource(appshot: appshot, sourceKind: kind, budget: budgetPerSource, now: now)
        }
    }

    private static func buildSource(
        appshot: Appshot,
        sourceKind: ScreenTextSourceKind,
        budget: Int,
        now: Date
    ) -> ScreenTextSnapshotSource {
        let rawText = appshot.windowText ?? ""
        let original = rawText.count
        let appName = appshot.appName ?? "Unknown"
        let windowTitle = appshot.windowTitle ?? ""
        let age = appshot.capturedAt.map { max(0, Int(now.timeIntervalSince($0).rounded())) }

        let quality = textQuality(for: rawText)

        guard original > budget else {
            // No truncation needed.
            return ScreenTextSnapshotSource(
                appName: appName,
                windowTitle: windowTitle,
                source: sourceKind,
                capturedSecondsAgo: age,
                text: rawText,
                originalCharCount: original,
                returnedCharCount: original,
                truncated: false,
                textQuality: quality
            )
        }

        // Head+tail truncation: split budget with a slight head bias.
        // If budget is below minHeadChars, return an empty text entry (still shows up).
        guard budget >= minHeadChars else {
            return ScreenTextSnapshotSource(
                appName: appName,
                windowTitle: windowTitle,
                source: sourceKind,
                capturedSecondsAgo: age,
                text: "",
                originalCharCount: original,
                returnedCharCount: 0,
                truncated: true,
                textQuality: quality
            )
        }

        let tailChars = budget / 3
        let headChars = budget - tailChars - elisionMarker.count
        let safeHead = max(0, headChars)
        let safeTail = max(0, tailChars)

        let head = safeHead > 0 ? String(rawText.prefix(safeHead)) : ""
        let tail = safeTail > 0 ? String(rawText.suffix(safeTail)) : ""

        let truncated = head + elisionMarker + tail
        let returned = truncated.count

        return ScreenTextSnapshotSource(
            appName: appName,
            windowTitle: windowTitle,
            source: sourceKind,
            capturedSecondsAgo: age,
            text: truncated,
            originalCharCount: original,
            returnedCharCount: returned,
            truncated: true,
            textQuality: quality
        )
    }

    private static func textQuality(for text: String) -> TextQuality {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.count < 30 { return .sparse }
        // Single-token text — no whitespace at all — is not real prose or code.
        // Filenames ("scoreboard-finals-2024.png"), long identifiers, and slugs
        // all lack word boundaries; a ≥30-char filename must still be .sparse so
        // the escalation hint fires when vision is available (issue #137).
        // Real content (code, prose, multi-word UI text) always has spaces or
        // newlines between tokens.
        if !trimmed.contains(where: \.isWhitespace) { return .sparse }
        return .ok
    }

    /// Returns `"analyze_screen"` when `visionAvailable == true` AND all sources
    /// are `.empty` or `.sparse` (or there are no sources at all). Returns nil
    /// otherwise, causing the field to be omitted from the JSON output.
    ///
    /// Design: this is a hint to the Realtime model that it should call
    /// `analyze_screen` next rather than try to answer from window text alone.
    /// The hint is suppressed whenever any source has `.ok` quality, because
    /// window text is sufficient in that case.
    private static func buildRecommendedNextTool(
        visionAvailable: Bool,
        sources: [ScreenTextSnapshotSource]
    ) -> String? {
        guard visionAvailable else { return nil }
        // Zero sources → no window text at all → escalate.
        // Any .ok source → window text is sufficient → no hint.
        let allEmptyOrSparse = sources.allSatisfy {
            $0.textQuality == .empty || $0.textQuality == .sparse
        }
        return allEmptyOrSparse ? "analyze_screen" : nil
    }

    private static func buildInstruction(visionAvailable: Bool) -> String {
        // Name-your-source + staleness rules (#119). The model must never
        // silently answer from a stale armed capture when the user is asking
        // about the current screen.
        let base = "Always name the window you are reading from (e.g. 'From your Arc window: …'). "
            + "Sources marked armed_appshot are earlier captures the user deliberately attached — capturedSecondsAgo says how old. "
            + "The fresh_grab source is the user's CURRENT frontmost window. "
            + "If the question is about the current screen but the fresh_grab text is empty or sparse, say that window exposes no readable text and name the armed capture(s) you have instead — do not answer from them as if they were the screen. "
            + "Some apps (Google Docs, Gmail, image-only windows) expose little or no text. "
            + "A filename or window-chrome title alone (e.g. 'scoreboard-finals.png') is NOT sufficient content — treat it as sparse and escalate if vision is available."
        if visionAvailable {
            return base + " If no source can answer the question, call analyze_screen for a vision-capable answer."
        }
        return base
    }
}
