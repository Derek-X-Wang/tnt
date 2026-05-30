// TNTMac — the Desktop App that owns mic, hotkeys, TTS, UI, local memory,
// BYOK config, the WebSocket to OpenAI Realtime, and the Local Ingest port.
// One process per User (v0 is single-tenant by design — see CONTEXT.md).
//
// Launch sequence (M0/S2-S8):
//   1. If `tnt.has_onboarded` is unset, show `OnboardingHost`. The User
//      reads the privacy posture, clicks Continue, grants Microphone
//      and Input Monitoring TCC, and connects an OpenAI BYOK key.
//   2. After onboarding (or immediately on subsequent launches),
//      install the State Lamp (`MenuBarHost`), the global ⌥Space
//      listener (`HotkeyHost`), and the `VoiceTurnController` that
//      glues hotkey → mic capture → Realtime WS → speakers.
//   3. The DEBUG menu carries "Test WS Roundtrip" (M0/S7) and a
//      "Replace API Key…" item that opens `BYOKHost` for in-app key
//      cycling.

import AppKit
import SwiftUI

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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarHost: MenuBarHost?
    private var hotkeyHost: HotkeyHost?
    private var onboardingHost: OnboardingHost?
    private var byokHost: BYOKHost?
    private var voiceTurnController: VoiceTurnController?
    private var wsTestTask: Task<Void, Never>?
    // Sparkle owns its own update-check timer once `startingUpdater: true`.
    // Holding the wrapper keeps the controller alive for the app's
    // lifetime; deallocating it would silently stop scheduled checks.
    private let sparkle = SparkleMenuAction()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force-load placeholder modules so missing-symbol regressions
        // surface in the TNTMac build, not a later slice that finally
        // imports them for real.
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
            },
            onTestWSRoundtrip: { [weak self] in
                self?.runWSRoundtripTest()
            },
            onCheckForUpdates: { [weak self] in
                self?.sparkle.checkForUpdates()
            }
        )
        self.menuBarHost = menu

        // Voice override per ~/.tnt/config (TNTConfig.voice) when present;
        // otherwise the bilingual default `alloy`.
        let configuredVoice = Self.loadVoiceOverride() ?? "alloy"

        let voiceController = VoiceTurnController(
            menuBarHost: menu,
            apiKeyProvider: { try TNTCredentials.openAIKey() },
            voice: configuredVoice
        )
        self.voiceTurnController = voiceController

        let host = HotkeyHost(chord: chord) { [weak self, weak menu] event in
            guard let menu else { return }
            switch event {
            case .startListening:
                Task { await self?.voiceTurnController?.startListening() }
            case .stopListening:
                Task { await self?.voiceTurnController?.stopListening() }
            case .permissionChanged(let auth):
                menu.setPermissionStatus(auth == .granted ? .ok : .inputMonitoringRequired)
            }
        }

        self.hotkeyHost = host
        host.start()
    }

    private func presentReplaceAPIKey() {
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

    /// Read `~/.tnt/config` and return the optional Realtime `voice`
    /// override. Returns `nil` when the file is absent or empty so the
    /// caller can fall back to the bilingual default.
    private static func loadVoiceOverride() -> String? {
        let configPath = ("~/.tnt/config" as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: configPath)
        guard let config = try? TNTConfig.load(from: url) else { return nil }
        return config.voice
    }

    private func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    /// Hidden DEBUG-only one-shot WS round-trip — kept for M0/S7
    /// validation. Uses its own ephemeral client so it does not
    /// interfere with the long-lived Voice Turn connection.
    private func runWSRoundtripTest() {
        wsTestTask?.cancel()
        wsTestTask = Task { [weak self] in
            await self?.runWSRoundtripTestImpl()
        }
    }

    private func runWSRoundtripTestImpl() async {
        menuBarHost?.setLastErrorMessage(nil)

        let key: String
        do {
            key = try TNTCredentials.openAIKey()
        } catch {
            menuBarHost?.setState(.idle)
            menuBarHost?.setLastErrorMessage("OpenAI API key missing — Replace API Key…")
            return
        }

        // Playback-only use of the shared audio session — the engine
        // starts lazily on the first `enqueueBase64`. No separate output
        // engine (that two-engine design threw -10877 on real hardware).
        let audio = RealtimeAudioSession()

        let client = OpenAIRealtimeWSClient(apiKey: key)
        do {
            try await client.connect()
        } catch {
            audio.stop()
            return
        }

        menuBarHost?.setState(.thinking)
        try? await client.send(ResponseCreate(response: .init(
            modalities: ["audio", "text"],
            instructions: "Say hello in English."
        )))

        for await event in client.inbound {
            if Task.isCancelled { break }
            switch event {
            case .responseAudioDelta(let delta):
                if menuBarHost?.state != .speaking {
                    menuBarHost?.setState(.speaking)
                }
                audio.enqueueBase64(delta.delta)
            case .responseDone:
                break
            case .error(let err):
                let summary = err.error.message ?? err.error.code ?? "Realtime error"
                menuBarHost?.setLastErrorMessage("Realtime: \(summary)")
                break
            case .sessionCreated, .unknown:
                continue
            }
            if case .responseDone = event { break }
            if case .error = event { break }
        }

        await client.disconnect()
        try? await Task.sleep(nanoseconds: 300_000_000)
        audio.stop()
        menuBarHost?.setState(.idle)
    }
}
