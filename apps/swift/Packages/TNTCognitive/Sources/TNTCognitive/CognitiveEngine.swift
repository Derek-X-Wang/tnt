// CognitiveEngine — the Future Server Boundary protocol for durable
// thinking (per ADR-0003). v0 impl is `LocalOpenAIEngine`; v1 will be
// `RemoteEngine` calling `tnt-server`. All call sites depend on this
// protocol, never on the concrete impl — the composition root in
// `TNTMac` is the only file that constructs the concrete type.
//
// Scope: M1 ships `compose` only. Each milestone grows the protocol by
// exactly one method so each is independently shippable (per the milestones
// in docs/roadmap.md). Do not add `summarize`/`whatsPending`/etc. here
// until M2; do not add `extractCorrection` until M3.

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
}
