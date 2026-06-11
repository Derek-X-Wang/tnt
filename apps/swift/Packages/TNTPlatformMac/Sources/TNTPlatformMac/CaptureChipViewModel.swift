// CaptureChipViewModel — pure view-model for the Capture Chip menu-bar UI
// element (issue #81, M1; extended for Appshots in issue #102, M4a).
//
// Per CONTEXT.md (Capture Chip): "Menu-bar UI element that shows what context
// is currently attached (e.g. '📎 247 chars from Cursor', '📸 ×2 Cursor,
// Chrome'). Clickable to clear or preview." The view-model owns the display
// logic; the SwiftUI view itself stays manual-dogfood (no SwiftUI view tests
// v0, per the PRD).
//
// M4a additions (issue #102):
// - Appshot summary in the '📸 ×N App1, App2' style alongside the scalar summary.
// - Appshot-only CaptureSet is NOT the empty state (ADR-0004: in-memory screen
//   content must never be invisible while armed).
// - Per-appshot preview data: app name, window title, Window-Text snippet,
//   hasImage flag (always false in M4a).
// - clearLast() removes the newest armed Appshot; clear() remains the full clear.
//
// Design constraints:
// - Pure: imports only Foundation + TNTCore; no SwiftUI, no AppKit.
// - Testable: all display logic is a pure mapping from CaptureSet to String.
// - clear() transitions to the empty state — the SwiftUI layer calls this
//   when the user clicks the chip's clear button.

import Foundation
import TNTCore

// MARK: - Per-Appshot preview row

/// Preview data for one armed Appshot, exposed by the view-model for the
/// menu layer to render. Intentionally a value type with no visual dependencies.
public struct AppShotPreviewRow: Equatable, Sendable {
    /// Source app name (e.g. "Cursor").
    public let appName: String
    /// Source window title (e.g. "main.swift — tnt").
    public let windowTitle: String
    /// Truncated Window-Text snippet for preview.
    public let windowTextSnippet: String
    /// False in M4a (image tier arrives in M4b).
    public let hasImage: Bool

    public init(appName: String, windowTitle: String, windowTextSnippet: String, hasImage: Bool) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.windowTextSnippet = windowTextSnippet
        self.hasImage = hasImage
    }
}

// MARK: - CaptureChipViewModel

/// View-model for the **Capture Chip** — the menu-bar element that shows
/// what context is currently attached to the next Voice Turn.
///
/// Create with a `CaptureSet` (or `CaptureSet.empty` for the paused state).
/// Call `clear()` to transition to the empty state (e.g. when the user
/// dismisses the chip or a new Voice Turn starts). Call `clearLast()` to
/// remove the newest armed Appshot while preserving all other context.
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
    ///
    /// An appshot-only CaptureSet is NOT the empty state (ADR-0004: in-memory
    /// screen content must never be invisible while armed).
    public var isEmpty: Bool {
        currentCapture.isEmpty
    }

    /// A human-readable summary of the attached context, shown in the
    /// Capture Chip. Examples:
    /// - "📸 ×2 Cursor, Chrome · 42 chars · tnt"
    /// - "📸 ×1 Cursor"
    /// - "📸 ×2 Cursor, Cursor"
    /// - "Cursor · 42 chars · tnt"
    /// - "No context" (empty state)
    ///
    /// Appshot summary leads with "📸 ×N App1, App2" and composes with
    /// the scalar fields (selected text, project name) when both are present.
    public var summary: String {
        guard !currentCapture.isEmpty else {
            return Self.emptyLabel
        }

        var parts: [String] = []

        // Appshot summary leads: "📸 ×N App1, App2"
        if !currentCapture.appshots.isEmpty {
            parts.append(appshotSummarySegment)
        }

        // Scalar context: app name (if no appshots leading) and selected text.
        if currentCapture.appshots.isEmpty, let app = currentCapture.appName {
            parts.append(app)
        }

        if let selectedText = currentCapture.selectedText, !selectedText.isEmpty {
            parts.append("\(selectedText.count) chars")
        }

        if let project = currentCapture.project {
            // Only add project if it differs from the app name (avoids redundancy).
            let leadingName = currentCapture.appshots.isEmpty
                ? currentCapture.appName
                : nil  // when Appshots lead, project stands alone
            if leadingName != project.name {
                parts.append(project.name)
            }
        }

        return parts.isEmpty ? Self.emptyLabel : parts.joined(separator: " · ")
    }

    /// Preview rows for all armed Appshots, in armed order (oldest first).
    ///
    /// The menu layer uses this to render per-appshot preview rows showing
    /// source app, window title, Window-Text snippet, and image availability.
    public var appshotPreviewRows: [AppShotPreviewRow] {
        currentCapture.appshots.map { appshot in
            AppShotPreviewRow(
                appName: appshot.appName ?? "Unknown",
                windowTitle: appshot.windowTitle ?? "",
                windowTextSnippet: snippet(from: appshot.windowText),
                hasImage: false  // M4a: image tier not yet available
            )
        }
    }

    // MARK: - Actions

    /// Transition to the full empty state. Clears all scalar fields and all
    /// Appshots. Called when the user clicks "Clear all" or a new turn starts.
    public mutating func clear() {
        currentCapture = .empty
    }

    /// Remove the newest armed Appshot only. Scalar fields are preserved.
    /// Called when the user clicks "Clear last" on the Appshot chip.
    ///
    /// If no Appshots are armed, this is a no-op.
    public mutating func clearLast() {
        guard !currentCapture.appshots.isEmpty else { return }
        let remaining = Array(currentCapture.appshots.dropLast())
        currentCapture = CaptureSet(
            appName: currentCapture.appName,
            windowTitle: currentCapture.windowTitle,
            selectedText: currentCapture.selectedText,
            project: currentCapture.project,
            appshots: remaining
        )
    }

    // MARK: - Private

    /// The fixed display string for the empty/paused state.
    private static let emptyLabel = "No context"

    /// Maximum characters for a Window-Text snippet in preview rows.
    private static let snippetMaxChars = 80

    /// Build the "📸 ×N App1, App2" Appshot segment of the summary.
    private var appshotSummarySegment: String {
        let count = currentCapture.appshots.count
        let appNames = currentCapture.appshots.map { $0.appName ?? "Unknown" }
        let appList = appNames.joined(separator: ", ")
        return "📸 ×\(count) \(appList)"
    }

    /// Build a truncated snippet from a Window-Text string for preview.
    private func snippet(from windowText: String?) -> String {
        guard let text = windowText, !text.isEmpty else { return "" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > Self.snippetMaxChars else { return trimmed }
        return String(trimmed.prefix(Self.snippetMaxChars)) + "…"
    }
}
