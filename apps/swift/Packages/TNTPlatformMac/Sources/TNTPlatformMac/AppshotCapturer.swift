// AppshotCapturer — produces a frozen, text-only Appshot of the frontmost
// window (issue #34, M4a text tier). Permanent-client final class (ADR-0003).
//
// One call freezes the CONTEXT.md self-contained unit: Window Text + the
// source window's appName/windowTitle/project, captured together. imageJPEG
// stays nil throughout M4a (ScreenCaptureKit lands in M4b/#107) — so this
// path needs NO Screen Recording TCC, only Accessibility.
//
// Providers are injected so policy is testable without AX/TCC; production
// uses the real AX readers. Trust gating mirrors AccessibilityClient (#49):
// untrusted → nil (fail-soft, no reads), JIT prompt via the same gate.

import Foundation
import TNTCore

@MainActor
public final class AppshotCapturer {

    private let signals: WindowSignalsReading
    private let windowText: () -> String?
    private let trustGate: () -> Bool
    private let now: () -> Date

    public init(
        signals: WindowSignalsReading = AXWindowSignalsReader(),
        windowText: @escaping () -> String? = { AXWindowTextReader().readFrontmostWindowText() },
        trustGate: @escaping () -> Bool = AccessibilityClient.systemTrustGate,
        now: @escaping () -> Date = { Date() }
    ) {
        self.signals = signals
        self.windowText = windowText
        self.trustGate = trustGate
        self.now = now
    }

    /// Capture a frozen text-only Appshot of the frontmost window.
    ///
    /// Nil when Accessibility is untrusted or no frontmost app is readable.
    /// An app exposing no Window Text still yields a valid Appshot with
    /// frozen labels and nil text (the snapshot layer reports textQuality).
    public func captureNow() -> Appshot? {
        guard trustGate() else {
            TNTLog.app.info("AppshotCapturer: Accessibility not trusted — no capture (grant in System Settings → Privacy → Accessibility)")
            return nil
        }
        let raw = signals.read()
        guard raw.appName != nil || raw.windowTitle != nil else {
            TNTLog.app.info("AppshotCapturer: no readable frontmost window — no capture")
            return nil
        }
        let project: ProjectRef? = {
            guard let app = raw.appName, let title = raw.windowTitle else { return nil }
            return projectRef(appName: app, windowTitle: title)
        }()
        return Appshot(
            imageJPEG: nil,  // M4a text tier — image arrives with M4b (#107)
            windowText: windowText(),
            appName: raw.appName,
            windowTitle: raw.windowTitle,
            project: project,
            capturedAt: now()  // #119: snapshot reports per-source capture age
        )
    }
}
