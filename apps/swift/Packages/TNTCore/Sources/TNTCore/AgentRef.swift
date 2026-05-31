// AgentRef — identifies a Worker Agent (Claude Code, Cursor, etc.)
// that a Voice Turn can address. Stable value type shared between
// the Cognitive Engine (decides which agent a Rewrite targets) and
// the platform layer (reads the frontmost window to infer the agent).
//
// Per CONTEXT.md: a **Worker Agent** is an external AI agent TNT
// talks _to_ on the User's behalf. `AgentRef` is not a reference
// to TNT itself — TNT is the Personal Master Agent.

import Foundation

/// A stable, codable reference to a Worker Agent.
///
/// `key` is the canonical, machine-readable identifier (stable across
/// display-name changes). `displayName` is optional; callers should
/// use the canonical static statics for the well-known agents so the
/// key string is never hardcoded at call sites.
public struct AgentRef: Codable, Equatable, Hashable, Sendable {

    /// Stable machine-readable identifier. Use snake_case,
    /// e.g. `"claude-code"`, `"cursor"`. Never change after shipping.
    public let key: String

    /// Human-readable display name, e.g. `"Claude Code"`. Optional —
    /// omit when the key is already human-readable enough.
    public let displayName: String?

    public init(key: String, displayName: String? = nil) {
        self.key = key
        self.displayName = displayName
    }

    // MARK: - Canonical Worker Agent statics

    /// Claude Code — the primary v0 Worker Agent integration.
    public static let claudeCode = AgentRef(key: "claude-code", displayName: "Claude Code")

    /// Cursor — second v0 Worker Agent integration.
    public static let cursor = AgentRef(key: "cursor", displayName: "Cursor")
}
