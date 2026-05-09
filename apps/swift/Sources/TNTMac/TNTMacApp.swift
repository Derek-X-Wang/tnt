// TNTMac — the Desktop App that owns mic, hotkeys, TTS, UI, local memory,
// BYOK config, the WebSocket to OpenAI Realtime, and the Local Ingest port.
// One process per User (v0 is single-tenant by design — see CONTEXT.md).
//
// As of M0/S2 the app is menu-bar-only: `LSUIElement = YES` keeps it out
// of the Dock and out of the app switcher; the only user-visible surface
// is the State Lamp owned by `MenuBarHost` in `TNTPlatformMac`.

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
/// SwiftUI `Scene` — most importantly the `MenuBarHost` `NSStatusItem`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarHost: MenuBarHost?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force-load every package so any compile-error or missing-symbol
        // regression in a placeholder module fails the TNTMac build, not
        // a later slice that finally imports it for real.
        _ = TNTCoreModule.self
        _ = TNTRealtimeModule.self
        _ = TNTCognitiveModule.self
        _ = TNTMemoryModule.self
        _ = TNTIngestModule.self

        menuBarHost = MenuBarHost(initialState: .idle)
    }
}
