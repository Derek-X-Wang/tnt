// CaptureSetAssembler — pure function that normalizes raw frontmost-window
// signals into a `CaptureSet` without touching AppKit or the Accessibility
// API directly. The AX reads live in `AccessibilityClient` (#49); this
// module receives the already-read raw strings as inputs and does only
// normalization + heuristic derivation.
//
// This split (per the counsel review in issue #48) keeps the normalization
// logic unit-testable without Cocoa or TCC.
//
// Per ADR-0004: pasteboard is never involved — it is not an input and
// must not be added as a future parameter.

import Foundation
import TNTCore

// MARK: - Raw signals

/// Raw frontmost-window signals injected from the Accessibility layer.
/// All fields are optional because any signal may be unavailable (e.g.
/// AX permission denied, protected system window, browser app).
public struct RawWindowSignals: Sendable {
    /// Bundle name of the frontmost application, e.g. `"Cursor"`.
    public let appName: String?
    /// Title of the frontmost window, e.g. `"main.swift — tnt"`.
    public let windowTitle: String?
    /// Currently selected text in the frontmost window. Empty string
    /// and whitespace-only values are normalized to `nil`.
    public let selectedText: String?

    public init(
        appName: String? = nil,
        windowTitle: String? = nil,
        selectedText: String? = nil
    ) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.selectedText = selectedText
    }
}

// MARK: - Assembly function

/// Assemble a normalized `CaptureSet` from raw frontmost-window signals.
///
/// Normalizations applied:
/// - `selectedText`: empty string or whitespace-only → `nil`.
/// - `project`: derived from `appName` + `windowTitle` via
///   `projectRef(appName:windowTitle:)` (ProjectHeuristic). If the app
///   is unknown or the title is unparseable, `project` is `nil`.
/// - `appName` and `windowTitle`: passed through as-is (the AX layer
///   already trims them before injecting).
///
/// No pasteboard involvement — ADR-0004.
public func assembleCaptureSet(from signals: RawWindowSignals) -> CaptureSet {
    let normalizedSelection = signals.selectedText.flatMap { text -> String? in
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    let project: ProjectRef? = {
        guard let app = signals.appName, let title = signals.windowTitle else {
            return nil
        }
        return projectRef(appName: app, windowTitle: title)
    }()

    return CaptureSet(
        appName: signals.appName,
        windowTitle: signals.windowTitle,
        selectedText: normalizedSelection,
        project: project
    )
}
