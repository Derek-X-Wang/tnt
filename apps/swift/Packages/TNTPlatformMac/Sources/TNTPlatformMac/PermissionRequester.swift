// PermissionRequester — thin async wrapper around the macOS TCC APIs the
// onboarding flow needs. Keeping the platform calls behind one type lets
// `OnboardingCoordinator` stay pure-async and lets future tests inject a
// stub if we ever want to drive the SwiftUI view in isolation.
//
// Microphone uses `AVCaptureDevice.requestAccess(for: .audio)`, which
// shows the system mic prompt the first time it's called and returns the
// cached answer after.
//
// Input Monitoring uses `CGRequestListenEventAccess()` — same API
// `HotkeyHost` calls. Onboarding requests it eagerly so the chord works
// the moment the consent screen closes.

import AppKit
import AVFoundation

@MainActor
public final class PermissionRequester {

    /// Nonisolated so default arguments at call sites
    /// (`PermissionRequester()`) compile in synchronous nonisolated
    /// contexts. The TCC requests themselves stay `@MainActor`.
    public nonisolated init() {}

    public func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    public func requestInputMonitoring() async -> Bool {
        // CGRequestListenEventAccess is synchronous but blocking on the
        // main actor briefly is fine — the prompt itself is an OS-owned
        // alert, not something we render.
        CGRequestListenEventAccess()
    }
}
