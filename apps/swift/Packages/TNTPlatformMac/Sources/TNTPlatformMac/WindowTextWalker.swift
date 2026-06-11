// WindowTextWalker — pure tree-walking core for Window Text (issue #103, M4a).
//
// Per CONTEXT.md (Window Text): "The full text available from the frontmost
// window via the Accessibility API — visible text and text the app exposes
// outside the visible scroll area." One half of an Appshot.
//
// This module defines the `TextNode` protocol seam so the walking algorithm is
// fully unit-testable without AX/TCC. The real AX adapter (wrapping AXUIElement)
// is a separate file that land in the #34 HITL wiring.
//
// Design constraints (issue #103):
// - Pure: no AppKit, no ApplicationServices imports.
// - Depth/cycle guards: pathological AX trees (deep/cyclic) terminate with
//   partial text — never hang or crash.
// - Walk-abort cap: a configurable char limit that stops the walk when reached.
// - Role filtering: collect text-bearing roles; skip noise roles (menus, toolbars).
// - De-duplication: consecutive identical values are skipped.
// - Joined with newlines.

import Foundation

// MARK: - TextNode protocol

/// An injectable node in an AX-like tree. Conformers provide a role, a text
/// value, and a list of child nodes. The real AX adapter implements this
/// protocol using `AXUIElement`; tests implement it using `FakeTextNode`.
///
/// Using an existential-friendly shape (no `associatedtype`) so the walker can
/// store `[any TextNode]` without opaque generics.
public protocol TextNode {
    /// The accessibility role, e.g. `"AXTextArea"`, `"AXStaticText"`.
    var role: String? { get }
    /// The text value of this node, if any.
    var value: String? { get }
    /// Child nodes in visual/document order.
    var children: [any TextNode] { get }
}

// MARK: - WindowTextWalker

/// Walks an injected `TextNode` tree and collects all available text.
///
/// Text is gathered from text-bearing roles, de-duplicated (consecutive
/// identical values suppressed), joined with newlines, and capped at
/// `walkAbortCap` characters to guard against pathological trees.
///
/// Depth and cycle guards prevent infinite traversal on malformed trees.
public struct WindowTextWalker {

    // MARK: - Configuration

    /// Roles whose `value` is collected. Everything outside this set is
    /// traversed for children but its own value is ignored.
    public static let textBearingRoles: Set<String> = [
        "AXTextArea",
        "AXTextField",
        "AXStaticText",
        "AXWebArea",
        // Electron apps expose text under AXGroup in some versions.
        "AXTextView",
    ]

    /// Roles whose entire subtree is skipped (high-noise, low-signal).
    public static let skipRoles: Set<String> = [
        "AXMenu",
        "AXMenuItem",
        "AXMenuBar",
        "AXMenuBarItem",
        "AXToolbar",
    ]

    /// Maximum depth the walker will descend. Beyond this, subtrees are
    /// skipped with partial text already collected.
    public let maxDepth: Int

    /// Maximum number of unique nodes visited in total (cycle guard).
    public let maxVisited: Int

    /// Total character cap: the walk aborts as soon as the collected text
    /// reaches this limit (the caller may also apply a tighter per-source
    /// budget via the `ScreenTextSnapshotBuilder`).
    public let walkAbortCap: Int

    public init(
        maxDepth: Int = 64,
        maxVisited: Int = 2_000,
        walkAbortCap: Int = 64_000
    ) {
        self.maxDepth = maxDepth
        self.maxVisited = maxVisited
        self.walkAbortCap = walkAbortCap
    }

    // MARK: - Walk

    /// Walk the tree rooted at `root` and return the collected text.
    ///
    /// - Parameter root: The root node of the AX tree (e.g. the frontmost
    ///   window's `AXUIElement` wrapped in a `TextNode` adapter).
    /// - Returns: Collected text joined by newlines, capped at `walkAbortCap`.
    ///   Returns an empty string for an empty or all-noise tree.
    public func walk(root: any TextNode) -> String {
        var collector = Collector(walker: self)
        collector.visit(node: root, depth: 0)
        return collector.result()
    }

    // MARK: - Collector (mutable scratch state)

    private struct Collector {
        let walker: WindowTextWalker
        var lines: [String] = []
        var totalChars: Int = 0
        var visitCount: Int = 0
        var aborted: Bool = false
        var lastValue: String? = nil

        mutating func visit(node: any TextNode, depth: Int) {
            guard !aborted else { return }
            guard depth <= walker.maxDepth else { return }
            guard visitCount < walker.maxVisited else {
                aborted = true
                return
            }
            visitCount += 1

            let role = node.role

            // Skip noise subtrees entirely.
            if let r = role, walker.shouldSkip(role: r) { return }

            // Collect value if this is a text-bearing role.
            if let r = role, walker.isTextBearing(role: r),
               let raw = node.value {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                // De-dup: skip if identical to the previous collected value.
                if !trimmed.isEmpty, trimmed != lastValue {
                    lines.append(trimmed)
                    totalChars += trimmed.count + 1  // +1 for the joining newline
                    lastValue = trimmed

                    if totalChars >= walker.walkAbortCap {
                        aborted = true
                        return
                    }
                }
            }

            // Recurse into children.
            for child in node.children {
                guard !aborted else { return }
                visit(node: child, depth: depth + 1)
            }
        }

        func result() -> String {
            lines.joined(separator: "\n")
        }
    }

    // MARK: - Role queries

    private func isTextBearing(role: String) -> Bool {
        Self.textBearingRoles.contains(role)
    }

    private func shouldSkip(role: String) -> Bool {
        Self.skipRoles.contains(role)
    }
}
