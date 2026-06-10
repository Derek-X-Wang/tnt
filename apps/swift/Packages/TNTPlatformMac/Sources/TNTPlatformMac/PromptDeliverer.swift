// PromptDeliverer — permanent-client delivery effects, exactly-once (issue #83).
//
// Performs the delivery effects for the pending Rewrite: write to the pasteboard
// (write-only — ADR-0004 bans reading), play a chime, and fire a system notification.
//
// Per ADR-0003: this is a permanent-client `final class`, not behind a protocol.
// The OS sinks (pasteboard / chime / notification) sit behind tiny protocols
// injected at init so the exactly-once and never-read contract is unit-testable
// without an app bundle or system services.
//
// Design constraints (issue #83):
// - deliver(_ rewrite:) writes exactly once per call — never batches or deduplicates.
// - Never reads the pasteboard — ADR-0004 (pasteboard reading for context is banned).
// - Real OS sink impls are provided here but their live firing is verified in the
//   #51 hardware demo, not in these unit tests.
// - Imports Foundation + TNTCore only (no AppKit in the protocol layer; AppKit is
//   in the real sink impls which the app target instantiates).

import Foundation
import TNTCore

// MARK: - Sink protocols (injected for testability)

/// Write-only pasteboard abstraction. The real impl writes via NSPasteboard.
/// Reading is intentionally absent — PromptDeliverer never reads the pasteboard
/// (ADR-0004: pasteboard reading for context is banned).
public protocol PasteboardSink: AnyObject {
    /// Write a string to the pasteboard. Called exactly once per delivery.
    func write(_ string: String)
    /// Read from the pasteboard. Present on the protocol so the test can
    /// assert read-count == 0 via the fake; the real impl may also expose it
    /// for other uses (but PromptDeliverer never calls it).
    func read() -> String?
}

/// Chime (delivery sound) abstraction. The real impl plays via NSSound.
public protocol ChimeSink: AnyObject {
    /// Play the delivery chime. Called exactly once per delivery.
    func play()
}

/// Notification abstraction. The real impl fires via UNUserNotificationCenter.
public protocol NotificationSink: AnyObject {
    /// Fire a system notification with a message. Called exactly once per delivery.
    func fire(message: String)
}

// MARK: - PromptDeliverer

/// Performs the delivery effects for the pending Rewrite.
///
/// Call `deliver(_ rewrite:)` once per confirmed Rewrite. Each call:
/// 1. Writes `rewrite` to the pasteboard (exactly once, never reads).
/// 2. Plays the delivery chime.
/// 3. Fires a system notification.
///
/// All three effects are injected via tiny protocols so the contract is
/// unit-testable without an app bundle. Real OS sinks are provided
/// separately and wired in by the app target (`TNTMac`).
///
/// Not `Sendable`: constructed and called only on the main actor (the
/// `VoiceTurnController` delivery path). Dropping the conformance avoids the
/// non-Sendable-stored-sink warnings without forcing the test fakes — which
/// hold mutable call-count state — to become `Sendable` (issue #51).
public final class PromptDeliverer {

    private let pasteboard: PasteboardSink
    private let chime: ChimeSink
    private let notification: NotificationSink

    // MARK: - Init

    public init(
        pasteboard: PasteboardSink,
        chime: ChimeSink,
        notification: NotificationSink
    ) {
        self.pasteboard = pasteboard
        self.chime = chime
        self.notification = notification
    }

    // MARK: - Delivery

    /// Deliver the pending Rewrite: write to pasteboard, play chime, fire notification.
    ///
    /// - Parameter rewrite: The Rewrite string to deliver. Written verbatim to the
    ///   pasteboard so the user can paste it into the target Worker Agent.
    public func deliver(_ rewrite: String) {
        // 1. Write to pasteboard — exactly once, never read.
        pasteboard.write(rewrite)
        // 2. Play the delivery chime.
        chime.play()
        // 3. Fire the system notification.
        notification.fire(message: "Prompt copied to clipboard")
    }
}

// MARK: - Real OS sink implementations

/// Real pasteboard sink backed by Foundation's UIPasteboard equivalent on macOS.
/// Uses a simple UserDefaults-free string write; the app target must import AppKit
/// and use `NSPasteboardRealSink` instead for the live implementation.
///
/// Note: This stub is provided here so TNTPlatformMac compiles without AppKit.
/// The real AppKit-backed sink lives in the TNTMac app target (where AppKit is available).
/// TNTPlatformMac tests use `FakePasteboardSink` injected at init.
// (No AppKit-backed real sink here — TNTPlatformMac must not import AppKit per issue #83
//  dependency constraint. The TNTMac app target wires in the real NSPasteboard sink.)

/// Real chime sink stub — the actual NSSound sink lives in the TNTMac app target.
/// TNTPlatformMac unit tests use `FakeChimeSink`.

/// Real notification sink stub — the actual UNUserNotificationCenter sink lives in
/// the TNTMac app target. TNTPlatformMac unit tests use `FakeNotificationSink`.
