// AccessibilityClient — live frontmost-window capture for the Capture Set
// (issue #49). A permanent-client `final class` per ADR-0003: reading the
// frontmost window needs local OS access and never moves to tnt-server.
//
// Deep module: one `captureNow()` call hides the AX/NSWorkspace specifics.
// The raw reads sit behind the `WindowSignalsReading` seam (real impl:
// `AXWindowSignalsReader`); normalization is the pure `assembleCaptureSet`
// (#48). This type owns only the privacy gate + the composition of the two.
//
// Privacy (ADR-0004):
// - Accessibility permission is requested JUST-IN-TIME on first capture,
//   never at launch. Untrusted → `.empty` CaptureSet, fail-soft log, and
//   NO AX reads are attempted (the reader is not consulted at all).
// - Pasteboard is never read — it is not a signal and must not become one.

import Foundation
import TNTCore

// MARK: - The injectable read seam

/// Raw frontmost-window reads, injected so `AccessibilityClient` is testable
/// without Cocoa or TCC. Production: `AXWindowSignalsReader`. Pasteboard is
/// deliberately absent from this surface (ADR-0004).
public protocol WindowSignalsReading {
    func read() -> RawWindowSignals
}

// MARK: - AccessibilityClient

@MainActor
public final class AccessibilityClient {

    private let reader: WindowSignalsReading
    private let trustGate: () -> Bool

    /// - Parameters:
    ///   - reader: The raw-signal source. Defaults to the real AX reader.
    ///   - trustGate: Returns whether Accessibility is trusted, prompting
    ///     JIT when not (the default uses `AXIsProcessTrustedWithOptions`
    ///     with the system prompt enabled). Injected for tests.
    public init(
        reader: WindowSignalsReading = AXWindowSignalsReader(),
        trustGate: @escaping () -> Bool = AccessibilityClient.systemTrustGate
    ) {
        self.reader = reader
        self.trustGate = trustGate
    }

    /// Capture the frontmost app/window/selection as a `CaptureSet`.
    ///
    /// Re-checks trust on every call so a JIT grant takes effect on the next
    /// capture without an app restart. Untrusted → `.empty` (fail-soft, no
    /// crash, no reads) with a log line so "why is my context empty" is
    /// diagnosable.
    public func captureNow() -> CaptureSet {
        guard trustGate() else {
            TNTLog.app.info("captureNow: Accessibility not trusted — returning empty Capture Set (grant in System Settings → Privacy → Accessibility)")
            return .empty
        }
        return assembleCaptureSet(from: reader.read())
    }

    /// The real JIT trust gate: prompts the user (once, system-managed) when
    /// Accessibility is not yet granted, and returns the current trust state.
    public static func systemTrustGate() -> Bool {
        AXWindowSignalsReader.isProcessTrusted(promptIfNeeded: true)
    }
}
