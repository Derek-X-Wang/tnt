// TNTMac — the Desktop App that owns mic, hotkeys, TTS, UI, local memory,
// BYOK config, the WebSocket to OpenAI Realtime, and the Local Ingest port.
// One process per User (v0 is single-tenant by design — see CONTEXT.md).
//
// Launch sequence (M0/S2-S4):
//   1. If `tnt.has_onboarded` is unset, show `OnboardingHost`. The user
//      reads the privacy posture, clicks Continue, and grants Microphone
//      and Input Monitoring TCC permissions.
//   2. After onboarding (or immediately on subsequent launches),
//      install the State Lamp (`MenuBarHost`) and the global ⌥Space
//      listener (`HotkeyHost`).
//
// Mic capture itself lands later in M0/S6.

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
/// SwiftUI `Scene` — most importantly `MenuBarHost`, `HotkeyHost`, and
/// the one-shot `OnboardingHost`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarHost: MenuBarHost?
    private var hotkeyHost: HotkeyHost?
    private var onboardingHost: OnboardingHost?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force-load every package so any compile-error or missing-symbol
        // regression in a placeholder module fails the TNTMac build, not
        // a later slice that finally imports it for real.
        _ = TNTCoreModule.self
        _ = TNTRealtimeModule.self
        _ = TNTCognitiveModule.self
        _ = TNTMemoryModule.self
        _ = TNTIngestModule.self

        if OnboardingFlag.hasOnboarded() {
            installRuntime()
        } else {
            presentOnboarding()
        }
    }

    private func presentOnboarding() {
        let host = OnboardingHost { [weak self] in
            self?.onboardingHost = nil
            self?.installRuntime()
        }
        self.onboardingHost = host
        host.present()
    }

    private func installRuntime() {
        let chord = HotkeyChord.load()

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

    private func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }
}
