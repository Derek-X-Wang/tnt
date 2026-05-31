// CaptureSet — the bundle of context signals attached to a Voice Turn.
//
// Per CONTEXT.md (Capture Set): v0 set: `app_name`, `window_title`,
// `selected_text`, `project_name`, `workspace_path`, and (M4)
// `appshots` — zero or more Appshots of frontmost windows. Pasteboard
// is deliberately excluded (ADR-0004: too easy to accidentally exfiltrate
// copied secrets).
//
// Per ADR-0003: this is a concrete Codable value type in TNTCore,
// visible to both TNTCognitive (the Cognitive Engine) and
// TNTPlatformMac (the capture side). It does NOT go behind a protocol
// — it's a data shape, not a behavior.

import Foundation

/// The bundle of context signals the Desktop App attaches to a
/// **Voice Turn** before sending it to the **Cognitive Engine**.
///
/// Captured from the frontmost window at turn-start time (app name,
/// window title, selected text, project reference). M4 adds `appshots`
/// — zero or more frozen window captures (image + Window Text).
///
/// Note: pasteboard is explicitly **not** a field (ADR-0004).
public struct CaptureSet: Codable, Equatable, Sendable {

    /// The name of the frontmost application at capture time,
    /// e.g. `"Cursor"`, `"Xcode"`, `"Safari"`.
    public let appName: String?

    /// The title of the frontmost window at capture time,
    /// e.g. `"tnt — VoiceTurnController.swift"`.
    public let windowTitle: String?

    /// The user's current text selection in the frontmost window.
    /// Narrow pointer: only the highlighted span, not the full visible
    /// text (that is Window Text inside an Appshot — M4).
    public let selectedText: String?

    /// The project the user is working in, derived from the workspace
    /// path or window-title heuristic.
    public let project: ProjectRef?

    /// Zero or more Appshots armed for this Voice Turn (M4 / ADR-0006).
    /// Multiple Appshots stack into one turn (per CONTEXT.md:
    /// "compare this design to that spec"). Defaults to empty — M1
    /// turns have no Appshots.
    public let appshots: [Appshot]

    private enum CodingKeys: String, CodingKey {
        case appName = "app_name"
        case windowTitle = "window_title"
        case selectedText = "selected_text"
        case project
        case appshots
    }

    public init(
        appName: String? = nil,
        windowTitle: String? = nil,
        selectedText: String? = nil,
        project: ProjectRef? = nil,
        appshots: [Appshot] = []
    ) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.selectedText = selectedText
        self.project = project
        self.appshots = appshots
    }

    // MARK: - Convenience

    /// An empty CaptureSet — all fields nil, no appshots. Useful as the
    /// starting state before any context has been captured, and as a
    /// sentinel when capture is paused ("Pause capture" master switch).
    public static let empty = CaptureSet()

    /// True when no context has been captured (all scalar fields are nil
    /// and no Appshots are attached). The Cognitive Engine uses this to
    /// omit the context section of the Rewrite prompt rather than
    /// generating empty placeholders.
    public var isEmpty: Bool {
        appName == nil &&
        windowTitle == nil &&
        selectedText == nil &&
        project == nil &&
        appshots.isEmpty
    }
}
