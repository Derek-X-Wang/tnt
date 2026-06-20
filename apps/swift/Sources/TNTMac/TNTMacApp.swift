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

        let onboarded = OnboardingFlag.hasOnboarded()
        TNTLog.app.info("didFinishLaunching: hasOnboarded=\(onboarded) — \(onboarded ? "installing runtime" : "showing onboarding")")
        if onboarded {
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
        TNTLog.app.info("installRuntime: menu-bar lamp + hotkey listener, chord=\(chord.displayString, privacy: .public)")

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
            },
            onClearContext: { [weak self] in
                self?.voiceTurnController?.clearAttachedCapture()
            },
            onClearLastAppshot: { [weak self] in
                self?.voiceTurnController?.clearLastAppshot()
            }
        )
        self.menuBarHost = menu

        // Voice override per ~/.tnt/config (TNTConfig.voice) when present;
        // otherwise the bilingual default `alloy`.
        let configuredVoice = Self.loadVoiceOverride() ?? "alloy"

        // Appshot capture chain (M4b, #127): ScreenCaptureKit one-shot image
        // provider behind the AX text capturer. The image provider fails soft
        // (nil) when Screen Recording isn't granted — preflight only, the
        // prompt belongs to the first analyze_screen (JIT).
        let screenImageCapturer = ScreenImageCapturer()
        let appshotCapturer = AppshotCapturer(windowImage: {
            await screenImageCapturer.captureFrontmostWindowJPEG()
        })

        let voiceController = VoiceTurnController(
            menuBarHost: menu,
            apiKeyProvider: { try TNTCredentials.openAIKey() },
            voice: configuredVoice,
            compose: { agentRef, intent, raw, capture in
                // Per-call BYOK key fetch so a replaced key takes effect, and the
                // concrete LocalOpenAIEngine (the server-future CognitiveEngine,
                // ADR-0003) is named only here at the composition root.
                let key = try TNTCredentials.openAIKey()
                let engine: CognitiveEngine = LocalOpenAIEngine(apiKey: key)
                return try await engine.compose(target: agentRef, intent: intent, raw: raw, capture: capture)
            },
            // Real OS-backed delivery sinks (#51). PromptDeliverer is a permanent-
            // client final class (ADR-0003); the AppKit/UserNotifications sinks live
            // in this app target and are wired in only here.
            promptDeliverer: PromptDeliverer(
                pasteboard: NSPasteboardSink(),
                chime: NSSoundChimeSink(),
                notification: UNNotificationSink()
            ),
            // Live frontmost-window capture (#49). JIT Accessibility prompt on
            // first capture (never at launch); untrusted → empty Capture Set.
            captureContext: { [accessibilityClient = AccessibilityClient()] in
                accessibilityClient.captureNow()
            },
            // Appshot capture (M4a #34 / M4b #127). The sync path stays
            // text-only (resolver freshGrab seam); the async path adds the
            // window image when Screen Recording is ALREADY granted — the
            // provider preflights and never prompts, so the hotkey can't
            // fire a TCC dialog (JIT prompt is the first analyze_screen's).
            captureAppshot: { [appshotCapturer] in
                appshotCapturer.captureNow()
            },
            captureAppshotWithImage: { [appshotCapturer] in
                await appshotCapturer.captureNowWithImage()
            },
            // Vision Cognitive Engine (M4b, #128): same composition-root
            // pattern as compose — per-call BYOK key fetch, LocalOpenAIEngine
            // named only here (ADR-0003). Never logs request bodies.
            answerAboutScreen: { question, appshots in
                let key = try TNTCredentials.openAIKey()
                let engine: CognitiveEngine = LocalOpenAIEngine(apiKey: key)
                return try await engine.answerAboutScreen(question: question, appshots: appshots)
            },
            // THE vision-tier flag (#107 single source of truth): registers
            // analyze_screen in the session AND flips the Tier-1 snapshot's
            // escalation hint. M4b ships enabled.
            visionEnabled: true
        )
        self.voiceTurnController = voiceController

        // Launch mic pre-warm (issue #73 / AUHAL #141): initialize the AUHAL
        // capture unit now, in the background, so the FIRST Voice Turn skips
        // component setup. AUHAL prepare() does NOT start capture, so — unlike
        // the old AVAudioEngine prewarm — it does NOT light the mic indicator at
        // launch. Default-on (PrewarmSetting), and only when mic permission is
        // ALREADY granted — so a first-ever launch (pre-onboarding) never
        // triggers the TCC prompt out of context.
        if PrewarmSetting.isEnabled(), PermissionRequester().isMicrophoneGranted() {
            TNTLog.app.info("installRuntime: pre-warming audio device (mic granted, prewarm on)")
            voiceController.prewarmAudio()
        }

#if DEBUG
        // Dogfood hook for the Capture Chip (#52) until live AX capture (#49):
        // pushes a sample CaptureSet through the same controller path the real
        // capture will use, so preview + Clear Context are verifiable today.
        menu.debugAttachSampleContext = { [weak voiceController] in
            voiceController?.setAttachedCapture(CaptureSet(
                appName: "Cursor",
                windowTitle: "VoiceTurnController.swift — tnt",
                selectedText: "func startListening() async { … }",
                project: ProjectRef(name: "tnt", path: "/Users/derekxwang/Development/incubator/TnT/tnt")
            ))
        }
#endif

        let host = HotkeyHost(
            chord: chord,
            appshotChord: HotkeyChord.loadAppshot()
        ) { [weak self, weak menu] event in
            guard let menu else { return }
            switch event {
            case .startListening:
                Task { await self?.voiceTurnController?.startListening() }
            case .stopListening:
                Task { await self?.voiceTurnController?.stopListening() }
            case .captureAppshot:
                self?.voiceTurnController?.handleAppshotHotkey()
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
            case .sessionCreated, .unknown, .functionCallArgumentsDone:
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
