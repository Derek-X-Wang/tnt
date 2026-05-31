// ProjectRef — identifies the project a Voice Turn is operating in.
// Captured from the frontmost window (workspace path, window title
// heuristic) and attached to a CaptureSet. Used by the Cognitive
// Engine to scope Rewrites and by the Memory Store to scope preferences.
//
// Per CONTEXT.md: captured by the Desktop App (active window context)
// and passed into the Rewrite prompt. The Memory Store holds project-
// scoped preferences (e.g. "prefer terse prompts for this repo").

import Foundation

/// A codable reference to a project, captured at Voice Turn time.
///
/// `name` is required (always displayable); `path` is optional
/// because not all windows expose a workspace path (e.g. web apps,
/// chat tools).
public struct ProjectRef: Codable, Equatable, Sendable {

    /// Human-readable project name, e.g. `"tnt"`, `"myapp"`.
    /// Derived from the workspace directory name or window title
    /// heuristic; should be stable within a session.
    public let name: String

    /// Absolute filesystem path to the workspace root, if available.
    /// `nil` when the frontmost window is not a file-backed editor
    /// (e.g. a browser, a chat app).
    public let path: String?

    public init(name: String, path: String? = nil) {
        self.name = name
        self.path = path
    }
}
