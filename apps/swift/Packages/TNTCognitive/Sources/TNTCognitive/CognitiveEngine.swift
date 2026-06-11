// CognitiveEngine — the Future Server Boundary protocol for durable
// thinking (per ADR-0003). v0 impl is `LocalOpenAIEngine`; v1 will be
// `RemoteEngine` calling `tnt-server`. All call sites depend on this
// protocol, never on the concrete impl — the composition root in
// `TNTMac` is the only file that constructs the concrete type.
//
// Scope: M1 ships `compose`; M4b adds `answerAboutScreen`. Each milestone
// grows the protocol by exactly one method so each is independently shippable
// (per the milestones in docs/roadmap.md). Do not add `summarize`/
// `whatsPending`/etc. here until M2; do not add `extractCorrection` until M3.

import Foundation
import TNTCore

/// The durable thinking layer: Rewrites messy bilingual Voice Turn
/// transcripts into clean Worker Agent prompts, and (in later milestones)
/// summarizes Session Events, extracts corrections, and reflects on preferences.
///
/// This is the server-future seam: v0 ships `LocalOpenAIEngine`; when
/// `tnt-server` is built, `RemoteEngine` replaces it and all call sites
/// remain unchanged (ADR-0003).
public protocol CognitiveEngine: AnyObject, Sendable {

    // MARK: - M1: Rewrite

    /// Transform a messy bilingual Voice Turn transcript into a clean
    /// **Rewrite** — a single English Worker Agent prompt with technical
    /// terms preserved verbatim.
    ///
    /// - Parameters:
    ///   - target: The Worker Agent the Rewrite is addressed to (e.g. `.claudeCode`).
    ///   - intent: One-line intent distilled from the transcript (produced by the
    ///     Realtime tool's argument parsing, not a second LLM call).
    ///   - raw: The raw messy bilingual transcript the User spoke.
    ///   - capture: The Capture Set (app, window, selection, project) attached to
    ///     this Voice Turn.
    /// - Returns: A clean, single-paragraph English Worker Agent prompt.
    func compose(
        target: AgentRef,
        intent: String,
        raw: String,
        capture: CaptureSet
    ) async throws -> String

    // MARK: - M4b: Vision route

    /// Answer a user question about what's on screen using the vision-capable
    /// Cognitive Engine (Tier-2 escalation path, ADR-0006 amendment).
    ///
    /// Called when the Realtime model invoked `analyze_screen` after
    /// `read_screen_text` returned an empty/sparse snapshot. Routes
    /// image + Window Text from the provided **Appshots** through the
    /// vision model, never through the Realtime session.
    ///
    /// The caller (VisionOrchestrator, issue #126) owns:
    /// - Stale-token guard (drops result if a barge-in occurred).
    /// - Consume-on-success: only the armed Appshots that were resolved at
    ///   dispatch time are consumed, not any newly-armed ones.
    ///
    /// Failure contract: throws on transport error, HTTP error, or empty
    /// model response. VisionOrchestrator emits an error-shaped fco on throw.
    ///
    /// - Parameters:
    ///   - question: The user's question from the `analyze_screen` tool call.
    ///   - appshots: Resolved Appshots (armed + fresh grab) at dispatch time.
    /// - Returns: The model's answer as a plain-text string.
    func answerAboutScreen(
        question: String,
        appshots: [Appshot]
    ) async throws -> String
}
