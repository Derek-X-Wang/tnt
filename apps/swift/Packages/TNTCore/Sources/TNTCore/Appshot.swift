// Appshot — a self-contained, frozen context unit that bundles a
// frontmost-window image (JPEG) + the window's full available text
// (via Accessibility API), plus the source window's frozen context
// fields (app name, title, project) captured at the instant of the
// Appshot Hotkey press or the "look at this" voice command.
//
// Per CONTEXT.md (Appshot): "An Appshot is a self-contained context
// unit: at capture time it freezes not just image + Window Text but
// also the source window's app_name, window_title, and project
// together." So an Appshot armed in Cursor stays labeled "Cursor" even
// if the user switches to another app before speaking.
//
// Per ADR-0004: Appshots are user-initiated and visible (the Capture
// Chip shows source app + image + Window Text preview before send) —
// this is the privacy posture that permits AX-sourced text capture
// while the pasteboard read ban stands.
//
// Capture behavior (ScreenCaptureKit + AX reads) lives in
// TNTPlatformMac — this file is pure data. Never written to disk by
// default; held in memory for the duration of the Voice Turn only.

import Foundation

/// A frozen, self-contained Appshot captured from the frontmost window.
///
/// Both fields are optional: some apps only expose window text (no
/// Screen Recording permission), some only expose images (Accessibility
/// denied), and some expose both. `isEmpty` is true only when both are nil.
public struct Appshot: Codable, Equatable, Sendable {

    /// JPEG image of the frontmost window at capture time.
    /// `nil` if Screen Recording TCC was not granted or the window
    /// could not be captured (e.g. protected system dialogs).
    /// Per ADR-0004: JPEG quality 80, never written to disk by default.
    public let imageJPEG: Data?

    /// Full text available from the frontmost window via the Accessibility
    /// API — visible text **and** text exposed outside the visible scroll
    /// area. Per CONTEXT.md (Window Text): distinct from `selectedText`
    /// in `CaptureSet`, which is only the current highlight. Some apps
    /// (Google Docs, Gmail) expose only the screenshot, not off-screen text.
    public let windowText: String?

    // MARK: - Frozen source-window context

    /// Name of the source app at capture time, e.g. `"Cursor"`.
    /// Frozen so a Cursor Appshot stays labeled "Cursor" even if the
    /// user switches to Slack before speaking.
    public let appName: String?

    /// Title of the source window at capture time.
    public let windowTitle: String?

    /// Project the source window was in at capture time.
    public let project: ProjectRef?

    private enum CodingKeys: String, CodingKey {
        case imageJPEG = "image_jpeg"
        case windowText = "window_text"
        case appName = "app_name"
        case windowTitle = "window_title"
        case project
    }

    public init(
        imageJPEG: Data? = nil,
        windowText: String? = nil,
        appName: String? = nil,
        windowTitle: String? = nil,
        project: ProjectRef? = nil
    ) {
        self.imageJPEG = imageJPEG
        self.windowText = windowText
        self.appName = appName
        self.windowTitle = windowTitle
        self.project = project
    }

    /// True when no content has been captured — both `imageJPEG` and
    /// `windowText` are nil. An Appshot with only context metadata but
    /// no content is still considered empty (it brings no new signal
    /// to the Cognitive Engine).
    public var isEmpty: Bool {
        imageJPEG == nil && windowText == nil
    }
}
