// ArmedAppshotStore + merge + resolver + arming coordinator (issue #104, M4a).
//
// Implements the persist-until-consumed Appshot lifecycle per CONTEXT.md:
// "An armed Appshot persists until consumed or cleared." A voice-pulled
// fresh grab clears at turn end; armed Appshots survive across turns.
//
// All four pieces are pure (Foundation + TNTCore only; no AppKit, no AX):
//
// 1. ArmedAppshotStore — [Appshot] with arm/clearAll/clearLast.
// 2. mergeArmedAppshots — frozen-context precedence: newest-armed non-nil
//    field wins the top-level CaptureSet fields; the `appshots` array is
//    the source of truth.
// 3. ScreenSourceResolver — mixed mode per #119: armed PLUS a labeled fresh
//    grab of the current frontmost window (fresh supersedes a same-window
//    armed duplicate).
// 4. AppshotArmingCoordinator — press→capture→arm→chip-update policy with
//    injected closures so the app-layer wiring is a thin adapter.

import Foundation
import TNTCore

// MARK: - 1. ArmedAppshotStore

/// Holds the list of armed Appshots. Appshots persist until consumed (M4b)
/// or cleared via `clearAll()` / `clearLast()`.
///
/// - `arm(_:)` appends; stacking is intentional (compare two windows).
/// - `clearAll()` empties the store.
/// - `clearLast()` removes the newest (last-armed) Appshot.
public struct ArmedAppshotStore: Equatable, Sendable {

    private var _appshots: [Appshot] = []

    public init() {}

    /// All currently armed Appshots, in arm order (oldest first).
    public var appshots: [Appshot] { _appshots }

    /// The number of currently armed Appshots.
    public var count: Int { _appshots.count }

    /// Arm a new Appshot (append). Stacking is supported — multiple Appshots
    /// can be armed before the next Voice Turn.
    public mutating func arm(_ appshot: Appshot) {
        _appshots.append(appshot)
    }

    /// Remove all armed Appshots. Called on Capture Chip "clear all".
    public mutating func clearAll() {
        _appshots.removeAll()
    }

    /// Remove the newest (last-armed) Appshot. Called on Capture Chip "clear last".
    /// No-op when the store is empty.
    public mutating func clearLast() {
        guard !_appshots.isEmpty else { return }
        _appshots.removeLast()
    }
}

// MARK: - 2. mergeArmedAppshots

/// Merge armed Appshots into a fresh `CaptureSet`, applying frozen-context
/// precedence rules.
///
/// Per CONTEXT.md: "When an armed Appshot is present, its frozen context takes
/// precedence; speak-time auto-capture only fills fields the Appshot did not
/// freeze."
///
/// Merging rules:
/// - **Newest-armed wins** for top-level `appName`, `windowTitle`, `project`
///   (iterating from newest to oldest; first non-nil wins each field).
/// - `fresh` fills any field that NO armed Appshot froze.
/// - `appshots` array in the result is `armed` (arm order); the `fresh`
///   `appshots` array is ignored (voice-pulled grabs are handled separately
///   by `ScreenSourceResolver`).
/// - Armed Appshots are never dropped.
///
/// - Parameters:
///   - fresh: The speak-time auto-captured `CaptureSet` (nil fields = not captured).
///   - armed: The armed Appshots from `ArmedAppshotStore` (arm order, oldest first).
/// - Returns: A merged `CaptureSet` with frozen-context precedence applied.
public func mergeArmedAppshots(fresh: CaptureSet, armed: [Appshot]) -> CaptureSet {
    guard !armed.isEmpty else {
        // No armed Appshots: return fresh as-is with empty appshots
        // (the fresh CaptureSet's own appshots field is ignored here).
        return CaptureSet(
            appName: fresh.appName,
            windowTitle: fresh.windowTitle,
            selectedText: fresh.selectedText,
            project: fresh.project,
            appshots: []
        )
    }

    // Newest-armed wins: search from newest (last) to oldest (first).
    let reversedArmed = armed.reversed()

    // For each top-level field, take the first non-nil value from newest-armed;
    // fall back to fresh if no armed Appshot provides the field.
    let mergedAppName = reversedArmed.compactMap(\.appName).first ?? fresh.appName
    let mergedWindowTitle = reversedArmed.compactMap(\.windowTitle).first ?? fresh.windowTitle
    let mergedProject = reversedArmed.compactMap(\.project).first ?? fresh.project

    // selectedText is a fresh-only field (Appshots don't carry selectedText).
    let mergedSelectedText = fresh.selectedText

    return CaptureSet(
        appName: mergedAppName,
        windowTitle: mergedWindowTitle,
        selectedText: mergedSelectedText,
        project: mergedProject,
        appshots: armed  // armed order is the source of truth
    )
}

// MARK: - 3. ScreenSourceResolver

/// The resolved inputs for one `read_screen_text` snapshot (#119 mixed mode):
/// armed Appshots PLUS a fresh grab of the current frontmost window, kept
/// separate so the snapshot can label each source `armed_appshot` vs
/// `fresh_grab` and the model knows what is on screen NOW.
public struct ResolvedScreenSources: Equatable, Sendable {

    /// Armed Appshots to include, in arm order — minus any superseded by
    /// `current` (same app + window title: the fresh grab IS that window's
    /// up-to-date text; duplicating it would waste the snapshot budget).
    public let armed: [Appshot]

    /// Fresh grab of the current frontmost window. Nil when capture failed
    /// (Accessibility untrusted, no readable frontmost window). This is the
    /// turn-scoped voice-pulled Appshot: the caller appends it to the turn's
    /// `CaptureSet.appshots` and it clears at turn end.
    public let current: Appshot?

    public init(armed: [Appshot], current: Appshot?) {
        self.armed = armed
        self.current = current
    }

    public var isEmpty: Bool { armed.isEmpty && current == nil }
}

/// Resolves the source Appshots for a `read_screen_text` tool call.
///
/// Mixed mode per #119 (supersedes the original armed-if-present-else-fresh
/// rule): the fresh-grab closure is ALWAYS called exactly once, so the model
/// always sees the current frontmost window alongside any armed captures —
/// the fix for stale armed Appshots silently answering about the wrong window.
///
/// - Note: `read_screen_text` (Tier 1) never *consumes* armed Appshots —
///   only `analyze_screen` (Tier 2, M4b) consumes on a successful answer.
///   The dedupe below only affects what enters ONE snapshot; the store is
///   never mutated here.
public struct ScreenSourceResolver {

    public init() {}

    /// Resolve the sources for a screen text query.
    ///
    /// - Parameters:
    ///   - armed: Currently armed Appshots from `ArmedAppshotStore`.
    ///   - freshGrab: Closure that captures a fresh frontmost-window Appshot.
    ///     Always called exactly once.
    /// - Returns: Armed Appshots (deduped against the fresh grab) plus the
    ///   fresh `current` grab, kept separate for per-source labeling.
    public func resolve(
        armed: [Appshot],
        freshGrab: () -> Appshot?
    ) -> ResolvedScreenSources {
        guard let current = freshGrab() else {
            // Capture failed: armed captures are all we have.
            return ResolvedScreenSources(armed: armed, current: nil)
        }
        // Fresh supersedes an armed shot of the SAME window (app + title):
        // identical text twice would eat the snapshot budget for nothing.
        // A same-app different-title armed shot is kept — it is a different
        // document, and capture age disambiguates.
        let kept = armed.filter { shot in
            !(current.appName != nil
              && shot.appName == current.appName
              && shot.windowTitle == current.windowTitle)
        }
        return ResolvedScreenSources(armed: kept, current: current)
    }
}

// MARK: - 4. AppshotArmingCoordinator

/// Drives the press→capture→arm→chip-update policy for the Appshot Hotkey.
///
/// Injected closures keep the business logic pure and testable:
/// - `capture`: `() -> Appshot?` — called when the hotkey fires; returns nil if
///   capture failed (e.g. Accessibility denied).
/// - `onChipUpdate`: `(CaptureSet) -> Void` — called with the merged `CaptureSet`
///   after each arm/clear so the Capture Chip reflects the new state.
///
/// The coordinator does NOT touch the `ScreenSourceResolver` or the turn
/// lifecycle — that lives in the tool-dispatch layer. Its single responsibility:
/// maintain the `ArmedAppshotStore` and notify the chip.
public final class AppshotArmingCoordinator {

    public typealias CaptureFunc = () -> Appshot?
    public typealias OnChipUpdate = (CaptureSet) -> Void

    // MARK: - Injected

    private let captureFunc: CaptureFunc
    private let onChipUpdate: OnChipUpdate

    // MARK: - State

    private var store: ArmedAppshotStore = ArmedAppshotStore()

    /// The current fresh context (speak-time auto-capture). The coordinator
    /// stores the last-set context so it can merge for chip updates.
    private var freshContext: CaptureSet = .empty

    // MARK: - Init

    public init(
        capture: @escaping CaptureFunc,
        onChipUpdate: @escaping OnChipUpdate
    ) {
        self.captureFunc = capture
        self.onChipUpdate = onChipUpdate
    }

    // MARK: - Public

    /// The count of currently armed Appshots (for session config hints).
    public var armedCount: Int { store.count }

    /// The currently armed Appshots (for resolver/session injection).
    public var armed: [Appshot] { store.appshots }

    /// Call when the Appshot Hotkey fires. Runs the capture closure, arms the
    /// result if non-nil, and notifies the chip.
    public func handleHotkeyPress() {
        guard let appshot = captureFunc() else { return }
        store.arm(appshot)
        notifyChip()
    }

    /// Clear all armed Appshots (Capture Chip "clear all" action).
    public func clearAll() {
        store.clearAll()
        notifyChip()
    }

    /// Clear the newest armed Appshot (Capture Chip "clear last" action).
    public func clearLast() {
        store.clearLast()
        notifyChip()
    }

    /// Update the fresh speak-time context. Call when the app captures the
    /// frontmost window at turn start. Used for merging in chip updates.
    public func setFreshContext(_ context: CaptureSet) {
        freshContext = context
        notifyChip()
    }

    // MARK: - Private

    private func notifyChip() {
        let merged = mergeArmedAppshots(fresh: freshContext, armed: store.appshots)
        onChipUpdate(merged)
    }
}
