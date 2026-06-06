// CaptureChipViewModel — pure view-model for the Capture Chip menu-bar UI
// element (issue #81, M1). Maps a CaptureSet to display strings: attached
// app, selected-text char count, project name, plus empty/paused state.
//
// Per CONTEXT.md (Capture Chip): "Menu-bar UI element that shows what context
// is currently attached (e.g. '📎 247 chars from Cursor', '📸 ×2 Cursor,
// Chrome'). Clickable to clear or preview." The view-model owns the display
// logic; the SwiftUI view itself stays manual-dogfood (no SwiftUI view tests
// v0, per the PRD).
//
// Design constraints:
// - Pure: imports only Foundation + TNTCore; no SwiftUI, no AppKit.
// - Testable: all display logic is a pure mapping from CaptureSet to String.
// - clear() transitions to the empty state — the SwiftUI layer calls this
//   when the user clicks the chip's clear button.

import Foundation
import TNTCore

/// View-model for the **Capture Chip** — the menu-bar element that shows
/// what context is currently attached to the next Voice Turn.
///
/// Create with a `CaptureSet` (or `CaptureSet.empty` for the paused state).
/// Call `clear()` to transition to the empty state (e.g. when the user
/// dismisses the chip or a new Voice Turn starts).
public struct CaptureChipViewModel: Sendable, Equatable {

    // MARK: - State

    private var currentCapture: CaptureSet

    // MARK: - Init

    public init(capture: CaptureSet = .empty) {
        self.currentCapture = capture
    }

    // MARK: - Display

    /// True when no context is attached (all fields nil, no Appshots).
    /// The Capture Chip uses this to show the paused/no-context badge.
    public var isEmpty: Bool {
        currentCapture.isEmpty
    }

    /// A human-readable summary of the attached context, shown in the
    /// Capture Chip. Examples:
    /// - "Cursor · 42 chars · tnt"
    /// - "Xcode · 16 chars"
    /// - "Safari"
    /// - "No context" (empty state)
    public var summary: String {
        guard !currentCapture.isEmpty else {
            return Self.emptyLabel
        }

        var parts: [String] = []

        if let app = currentCapture.appName {
            parts.append(app)
        }

        if let selectedText = currentCapture.selectedText, !selectedText.isEmpty {
            parts.append("\(selectedText.count) chars")
        }

        if let project = currentCapture.project {
            // Only add project if it differs from the app name (avoids redundancy
            // when the heuristic returns a project named identically to the app).
            if parts.first != project.name {
                parts.append(project.name)
            }
        }

        // If somehow all optional fields resolved to empty parts (unlikely but
        // defensive), fall through to the empty label so the chip is never blank.
        return parts.isEmpty ? Self.emptyLabel : parts.joined(separator: " · ")
    }

    // MARK: - Actions

    /// Transition to the empty state. Called when the user clears the chip
    /// or a new turn starts without context.
    public mutating func clear() {
        currentCapture = .empty
    }

    // MARK: - Private

    /// The fixed display string for the empty/paused state.
    private static let emptyLabel = "No context"
}
