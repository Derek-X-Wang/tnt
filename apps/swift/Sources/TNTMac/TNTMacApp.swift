// TNTMac — the Desktop App that owns mic, hotkeys, TTS, UI, local memory,
// BYOK config, the WebSocket to OpenAI Realtime, and the Local Ingest port.
// One process per User (v0 is single-tenant by design — see CONTEXT.md).
//
// Launch sequence (M0/S2-S5):
//   1. If `tnt.has_onboarded` is unset, show `OnboardingHost`. The User
//      reads the privacy posture, clicks Continue, grants Microphone
//      and Input Monitoring TCC, and connects an OpenAI BYOK key.
//   2. After onboarding (or immediately on subsequent launches),
//      install the State Lamp (`MenuBarHost`) and the global ⌥Space
//      listener (`HotkeyHost`). The menu offers a "Replace API Key…"
//      item that opens `BYOKHost` for in-app key cycling.

import AppKit
import SwiftUI

// Each package import is intentional: TNTMac is the composition root and
// must link every TNT package so missing-symbol regressions surface here.
// The four placeholder modules will be replaced with real types as later
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
/// SwiftUI `Scene` — `MenuBarHost`, `HotkeyHost`, the one-shot
/// `OnboardingHost`, and the on-demand `BYOKHost`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarHost: MenuBarHost?
    private var hotkeyHost: HotkeyHost?
    private var onboardingHost: OnboardingHost?
    private var byokHost: BYOKHost?
    private var audioCapture: VoiceProcessingIOAudioCapture?
    private var captureDrainTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force-load the placeholder modules so any compile-error or
        // missing-symbol regression in those packages fails the TNTMac
        // build, not a later slice that finally imports them for real.
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
            },
            onReplaceAPIKey: { [weak self] in
                self?.presentReplaceAPIKey()
            }
        )

        let capture = VoiceProcessingIOAudioCapture()
        self.audioCapture = capture

        let host = HotkeyHost(chord: chord) { [weak self, weak menu] event in
            guard let menu else { return }
            switch event {
            case .startListening:
                menu.setState(.listening)
                self?.startMicCapture()
            case .stopListening:
                menu.setState(.idle)
                menu.setMicLevel(nil)
                self?.stopMicCapture()
            case .permissionChanged(let auth):
                menu.setPermissionStatus(auth == .granted ? .ok : .inputMonitoringRequired)
            }
        }

        self.menuBarHost = menu
        self.hotkeyHost = host

        host.start()
    }

    private func startMicCapture() {
        guard let capture = audioCapture else { return }
        // Cancel any prior drain — `.listening` should always start
        // from a clean stream.
        captureDrainTask?.cancel()

        captureDrainTask = Task { [weak self] in
            do {
                try await capture.start()
            } catch {
                NSLog("[TNT] AudioCapture.start failed: \(error)")
                return
            }
            for await frame in capture.frames {
                if Task.isCancelled { break }
                let dB = AudioLevel.peakDB(from: frame)
                await MainActor.run {
                    self?.menuBarHost?.setMicLevel(dB)
                }
            }
        }
    }

    private func stopMicCapture() {
        captureDrainTask?.cancel()
        captureDrainTask = nil
        if let capture = audioCapture {
            Task { await capture.stop() }
        }
    }

    private func presentReplaceAPIKey() {
        // Tear down any previous host first; opening a second window
        // while the first is alive should bring the existing one to
        // front rather than stacking duplicates.
        if let existing = byokHost {
            existing.present()
            return
        }
        let host = BYOKHost { [weak self] in
            self?.byokHost = nil
        }
        self.byokHost = host
        host.present()
    }

    private func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }
}
