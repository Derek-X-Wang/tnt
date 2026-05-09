// TNTMac — the Desktop App that owns mic, hotkeys, TTS, UI, local memory,
// BYOK config, the WebSocket to OpenAI Realtime, and the Local Ingest port.
// One process per User (v0 is single-tenant by design — see CONTEXT.md).
//
// As of M0/S3 the composition root wires `HotkeyHost` (global ⌥Space
// listener) to `MenuBarHost` (State Lamp). The first chord press
// triggers the Input Monitoring TCC prompt; if denied, the menu shows
// "⚠ Input Monitoring required" + Open Settings + Retry. Mic capture
// is intentionally not wired here — that lands in M0/S6.

import AppKit
import SwiftUI

// Each package import is intentional: TNTMac is the composition root and
// must link every TNT package so missing-symbol regressions surface here.
// The five placeholder modules will be replaced with real types as later
// milestones land (Cognitive Engine M1, Memory Store + Ingest M2, etc.).
import TNTCore
import TNTRealtime
import TNTCognitive
import TNTMemory
import TNTIngest
import TNTPlatformMac

@main
struct TNTMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // `Settings` keeps the SwiftUI lifecycle alive without opening any
        // window on launch — required for an LSUIElement (menu-bar-only)
        // app. The body intentionally remains empty until M3 wires real
        // settings (preferences, BYOK key entry, etc.).
        Settings { EmptyView() }
    }
}

/// Owns long-lived AppKit resources that don't fit cleanly inside a
/// SwiftUI `Scene` — most importantly `MenuBarHost` and `HotkeyHost`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarHost: MenuBarHost?
    private var hotkeyHost: HotkeyHost?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force-load every package so any compile-error or missing-symbol
        // regression in a placeholder module fails the TNTMac build, not
        // a later slice that finally imports it for real.
        _ = TNTCoreModule.self
        _ = TNTRealtimeModule.self
        _ = TNTCognitiveModule.self
        _ = TNTMemoryModule.self
        _ = TNTIngestModule.self

        let chord = HotkeyChord.load()

        // Build the MenuBarHost first so the HotkeyHost listener has a
        // stable target. Permission callbacks bounce back to the
        // hotkey host once it exists.
        let menu = MenuBarHost(
            initialState: .idle,
            permissionStatus: .ok,
            onOpenInputMonitoringSettings: { [weak self] in
                self?.openInputMonitoringSettings()
            },
            onRetryInputMonitoring: { [weak self] in
                self?.hotkeyHost?.recheckAuthorization()
            }
        )

        let host = HotkeyHost(chord: chord) { [weak menu] event in
            guard let menu else { return }
            switch event {
            case .startListening:
                menu.setState(.listening)
            case .stopListening:
                menu.setState(.idle)
            case .permissionChanged(let auth):
                menu.setPermissionStatus(auth == .granted ? .ok : .inputMonitoringRequired)
            }
        }

        self.menuBarHost = menu
        self.hotkeyHost = host

        host.start()
    }

    /// Opens System Settings → Privacy & Security → Input Monitoring.
    /// The pane URL is the documented deep-link for that TCC category.
    private func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }
}
