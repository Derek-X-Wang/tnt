// AXWindowSignalsReader — the real Accessibility-API implementation of
// `WindowSignalsReading` (issue #49). Lives in its own AppKit-importing file
// so `CaptureSetAssembler` and `ProjectHeuristic` stay AppKit-free (the
// structural contract from #48).
//
// Reads three signals from the frontmost application:
// - app name:    NSWorkspace (no AX needed)
// - window title: AXFocusedWindow → AXTitle
// - selection:    AXFocusedUIElement → AXSelectedText
//
// Every read fails soft: a denied attribute, protected window, or app that
// exposes no AX tree yields nils, never an error. Some apps (Google Docs,
// Electron apps with AX disabled) expose partial or no text — expected.
//
// Pasteboard is never read (ADR-0004).

import AppKit
import ApplicationServices
import TNTCore

public final class AXWindowSignalsReader: WindowSignalsReading {

    public init() {}

    public func read() -> RawWindowSignals {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return RawWindowSignals()
        }

        let appName = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        return RawWindowSignals(
            appName: appName?.isEmpty == false ? appName : nil,
            windowTitle: Self.focusedWindowTitle(of: axApp),
            selectedText: Self.focusedSelection(of: axApp)
        )
    }

    /// Non-prompting by default; with `promptIfNeeded` the system shows the
    /// one-time Accessibility consent flow (System Settings deep-link).
    public static func isProcessTrusted(promptIfNeeded: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptIfNeeded] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - AX reads (each fails soft to nil)

    private static func focusedWindowTitle(of axApp: AXUIElement) -> String? {
        guard let window = copyElement(axApp, kAXFocusedWindowAttribute) else {
            return nil
        }
        let trimmed = copyString(window, kAXTitleAttribute)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func focusedSelection(of axApp: AXUIElement) -> String? {
        guard let element = copyElement(axApp, kAXFocusedUIElementAttribute) else {
            return nil
        }
        // Raw value only — assembleCaptureSet normalizes whitespace/empty.
        return copyString(element, kAXSelectedTextAttribute)
    }

    /// CF types carry no Swift runtime type info, so `as?` cannot reject a
    /// wrong-typed attribute — verify with `CFGetTypeID` before treating a
    /// value as an `AXUIElement` (a mis-typed ref passed to AX calls is UB).
    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copyRaw(element, attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copyRaw(element, attribute),
              CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! CFString) as String
    }

    private static func copyRaw(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
