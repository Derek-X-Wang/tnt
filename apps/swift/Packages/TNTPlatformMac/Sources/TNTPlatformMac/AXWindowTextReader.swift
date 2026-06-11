// AXWindowTextReader — the real Accessibility adapter feeding the pure
// WindowTextWalker (#103) for **Window Text** capture (issue #34, M4a).
// Lives in its own AppKit/ApplicationServices-importing file so the walker
// stays AppKit-free (same structural contract as AXWindowSignalsReader/#49).
//
// Wraps the frontmost window's AXUIElement tree as the walker's TextNode
// seam. Every AX read fails soft (CFGetTypeID-guarded, same as #49 — Swift
// `as?` cannot reject wrong-typed CF refs). Electron AXManualAccessibility
// forcing is deliberately SKIPPED in v0 (target-app performance risk).

import AppKit
import ApplicationServices
import TNTCore

/// A lazy `TextNode` over a live `AXUIElement`. Children are fetched on
/// access; the walker's depth/cycle/cap guards bound total work.
struct AXTextNode: TextNode {

    let element: AXUIElement

    var role: String? {
        Self.copyString(element, kAXRoleAttribute)
    }

    var value: String? {
        Self.copyString(element, kAXValueAttribute)
    }

    var children: [any TextNode] {
        guard let raw = Self.copyRaw(element, kAXChildrenAttribute),
              CFGetTypeID(raw) == CFArrayGetTypeID() else { return [] }
        let array = raw as! [AnyObject]
        return array.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            return AXTextNode(element: item as! AXUIElement)
        }
    }

    // MARK: - CF-safe reads (mirrors AXWindowSignalsReader)

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copyRaw(element, attribute),
              CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! CFString) as String
    }

    fileprivate static func copyRaw(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}

/// Reads the frontmost window's full **Window Text** by walking its AX tree.
public final class AXWindowTextReader {

    private let walker = WindowTextWalker()

    public init() {}

    /// Best-effort Window Text of the frontmost window. Nil when there is no
    /// frontmost app, no focused window, or the app exposes no AX text
    /// (Google Docs/Gmail-class apps) — a valid degraded outcome, not an error.
    public func readFrontmostWindowText() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let raw = AXTextNode.copyRaw(axApp, kAXFocusedWindowAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let text = walker.walk(root: AXTextNode(element: raw as! AXUIElement))
        return text.isEmpty ? nil : text
    }
}
