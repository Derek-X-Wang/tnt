// ScreenTextSnapshot — Tier-1 `function_call_output` payload builder for M4a.
//
// Turns `(question, [Appshot], visionAvailable: Bool)` into the JSON string
// the Realtime model reads as the `read_screen_text` tool's output.
//
// Per ADR-0006 (amendment): Tier 1 returns Window-Text snapshots directly —
// no Cognitive Engine call, no image bytes. This builder is the single source
// of truth for that JSON shape.
//
// Design constraints (issue #100):
// - Pure: imports Foundation + TNTCore only; no AppKit, no ApplicationServices.
// - Deterministic output via explicit `Encodable` conformance (stable key order).
// - `visionAvailable: false` in M4a (no escalation hint; M4b flips to true).
// - Total text budget ~8,000 chars across sources; head+tail truncation.
// - Empty/sparse text is a valid snapshot — never an error.

import Foundation
import TNTCore

// MARK: - Source kind

/// Whether the Appshot came from the arm queue or a fresh voice-pulled grab.
/// Corresponds to ADR-0006's "armed Appshots if present, else fresh grab" rule.
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
    public let text: String
    public let originalCharCount: Int
    public let returnedCharCount: Int
    public let truncated: Bool
    public let textQuality: TextQuality

    private enum CodingKeys: String, CodingKey {
        case appName        = "appName"
        case windowTitle    = "windowTitle"
        case source
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
        text: String,
        originalCharCount: Int,
        returnedCharCount: Int,
        truncated: Bool,
        textQuality: TextQuality
    ) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.source = source
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
public struct ScreenTextSnapshot: Encodable, Equatable, Sendable {

    public let kind: String
    public let version: Int
    public let question: String?
    public let sources: [ScreenTextSnapshotSource]
    public let fullVisionAvailable: Bool
    public let instruction: String

    private enum CodingKeys: String, CodingKey {
        case kind
        case version
        case question
        case sources
        case fullVisionAvailable
        case instruction
    }

    public init(
        question: String?,
        sources: [ScreenTextSnapshotSource],
        fullVisionAvailable: Bool,
        instruction: String
    ) {
        self.kind = "screen_text_snapshot"
        self.version = 1
        self.question = question
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

    /// Build a snapshot from a list of Appshots and an optional question.
    ///
    /// - Parameters:
    ///   - question: The user's question from the tool call arguments.
    ///   - appshots: The source Appshots (armed-order preferred).
    ///   - sourceKind: The kind to tag all sources with (`armed_appshot` or `fresh_grab`).
    ///   - visionAvailable: Whether `analyze_screen` is registered. M4a passes `false`;
    ///     M4b flips this to `true` and the builder emits the escalation hint.
    /// - Returns: A `ScreenTextSnapshot` ready for `jsonString()`.
    public static func build(
        question: String?,
        appshots: [Appshot],
        sourceKind: ScreenTextSourceKind,
        visionAvailable: Bool
    ) -> ScreenTextSnapshot {
        let sources = buildSources(appshots: appshots, sourceKind: sourceKind)
        let instruction = buildInstruction(visionAvailable: visionAvailable)
        return ScreenTextSnapshot(
            question: question,
            sources: sources,
            fullVisionAvailable: visionAvailable,
            instruction: instruction
        )
    }

    // MARK: - Private helpers

    private static func buildSources(
        appshots: [Appshot],
        sourceKind: ScreenTextSourceKind
    ) -> [ScreenTextSnapshotSource] {
        guard !appshots.isEmpty else { return [] }

        // Distribute the budget evenly across sources; each source gets at least
        // one slot in the output even if the budget is fully exhausted.
        let budgetPerSource = max(1, totalBudget / appshots.count)

        return appshots.map { appshot in
            buildSource(appshot: appshot, sourceKind: sourceKind, budget: budgetPerSource)
        }
    }

    private static func buildSource(
        appshot: Appshot,
        sourceKind: ScreenTextSourceKind,
        budget: Int
    ) -> ScreenTextSnapshotSource {
        let rawText = appshot.windowText ?? ""
        let original = rawText.count
        let appName = appshot.appName ?? "Unknown"
        let windowTitle = appshot.windowTitle ?? ""

        let quality = textQuality(for: rawText)

        guard original > budget else {
            // No truncation needed.
            return ScreenTextSnapshotSource(
                appName: appName,
                windowTitle: windowTitle,
                source: sourceKind,
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
        return .ok
    }

    private static func buildInstruction(visionAvailable: Bool) -> String {
        if visionAvailable {
            return "Answer only if the question can be answered from this text. If the text is insufficient or empty, call analyze_screen for a vision-capable answer."
        } else {
            return "Answer only if the question can be answered from this text. Some apps (Google Docs, Gmail, image-only windows) may expose little or no text — the snapshot will say so."
        }
    }
}
