// VoiceTurnController — glue layer that runs one **Voice Turn** by
// coordinating `RealtimeAudioSession`, `OpenAIRealtimeWSClient`, and
// `MenuBarHost` against a pure `VoiceTurnFlow` state machine. Lives in
// the app target so it can import every package the v0 voice path
// touches.
//
// The state-transition logic itself is in `TNTPlatformMac.VoiceTurnFlow`
// and unit-tested there; this class is the thinnest possible bridge
// between the flow's directives and the actual hardware / network.
//
// Audio is a single `RealtimeAudioSession` (one AVAudioEngine, capture +
// playback) — see that file for why two engines fail on real hardware.

import AppKit
import Foundation
import TNTCore
import TNTPlatformMac
import TNTRealtime

@MainActor
final class VoiceTurnController {

    private var flow = VoiceTurnFlow()
    private let audio: RealtimeAudioSession
    private var client: OpenAIRealtimeWSClient?

    private var captureDrainTask: Task<Void, Never>?
    private var inboundTask: Task<Void, Never>?

    private weak var menuBarHost: MenuBarHost?
    private let apiKeyProvider: () throws -> String
    private let voice: String

    init(
        menuBarHost: MenuBarHost,
        apiKeyProvider: @escaping () throws -> String,
        voice: String = "alloy"
    ) {
        self.menuBarHost = menuBarHost
        self.apiKeyProvider = apiKeyProvider
        self.voice = voice
        self.audio = RealtimeAudioSession()
    }

    // MARK: - Hotkey edges

    func startListening() async {
        await ensureConnection()
        guard client != nil else { return }
        apply(flow.handle(.hotkeyStartListening))
    }

    func stopListening() async {
        apply(flow.handle(.hotkeyStopListening))
    }

    func tearDown() async {
        captureDrainTask?.cancel()
        inboundTask?.cancel()
        captureDrainTask = nil
        inboundTask = nil
        audio.stop()
        if let client {
            await client.disconnect()
        }
        client = nil
    }

    // MARK: - WS lifecycle

    private func ensureConnection() async {
        if client != nil { return }

        let apiKey: String
        do {
            apiKey = try apiKeyProvider()
        } catch {
            menuBarHost?.setLastErrorMessage("OpenAI API key missing — Replace API Key…")
            return
        }

        let c = OpenAIRealtimeWSClient(apiKey: apiKey)
        do {
            try await c.connect()
        } catch {
            // Nothing to leak — `connect()` failed, so no live socket.
            menuBarHost?.setLastErrorMessage("Could not connect: \(error.localizedDescription)")
            return
        }

        self.client = c
        menuBarHost?.setLastErrorMessage(nil)

        // Configure the session for the bilingual v0 scope on every
        // connect — the OpenAI Realtime session does not survive the
        // socket, so re-sending on reconnect keeps language hints +
        // voice + system prompt aligned.
        do {
            try await c.send(SessionUpdate.bilingualV0(voice: voice))
        } catch {
            menuBarHost?.setLastErrorMessage("Could not configure session: \(error.localizedDescription)")
        }

        startInboundDrain(on: c)
        startCaptureDrain()
    }

    private func startInboundDrain(on client: OpenAIRealtimeWSClient) {
        let stream = client.inbound
        inboundTask = Task { [weak self] in
            for await event in stream {
                if Task.isCancelled { break }
                self?.handle(serverEvent: event)
            }
        }
    }

    /// One long-lived loop that forwards mic frames to the WS for the
    /// whole connection. Frames are only physically produced while the
    /// `RealtimeAudioSession` tap is installed (between `.startCapture`
    /// and `.stopCapture`), so this naturally idles between Voice Turns.
    ///
    /// This replaces the old per-listening-window `for await capture.frames`
    /// loop, which re-iterated a single-consumer `AsyncStream` each turn —
    /// fine on turn 1, silently empty on turn 2.
    private func startCaptureDrain() {
        guard captureDrainTask == nil else { return }
        captureDrainTask = Task { [weak self] in
            guard let self else { return }
            for await frame in self.audio.frames {
                if Task.isCancelled { break }
                let dB = AudioLevel.peakDB(from: frame)
                let base64 = frame.base64EncodedString()
                try? await self.client?.send(InputAudioBufferAppend(audio: base64))
                self.menuBarHost?.setMicLevel(dB)
            }
        }
    }

    private func handle(serverEvent event: RealtimeServerEvent) {
        switch event {
        case .responseAudioDelta(let delta):
            apply(flow.handle(.audioDelta(delta.delta)))
        case .responseDone:
            apply(flow.handle(.responseDone))
        case .error(let err):
            let summary = err.error.message ?? err.error.code ?? "Realtime error"
            apply(flow.handle(.responseError(summary)))
            // Drop the dead client so the next hotkey press reconnects.
            self.client = nil
        case .sessionCreated, .unknown:
            return
        }
    }

    // MARK: - Directive execution

    private func apply(_ directives: [VoiceTurnDirective]) {
        for directive in directives {
            switch directive {
            case .setState(let state):
                menuBarHost?.setState(state)
                if state == .idle {
                    menuBarHost?.setMicLevel(nil)
                }
            case .startCapture:
                do {
                    try audio.startCapture()
                } catch {
                    menuBarHost?.setLastErrorMessage("Mic start failed: \(error.localizedDescription)")
                }
            case .stopCapture:
                audio.stopCapture()
            case .sendCommitAndCreate:
                sendCommitAndCreate()
            case .sendCancelAndClear:
                sendCancelAndClear()
            case .enqueuePlayback(let payload):
                audio.enqueueBase64(payload)
            case .stopPlayer:
                audio.flushPlayback()
            case .restartPlayer:
                audio.resumePlayback()
            case .showError(let message):
                menuBarHost?.setLastErrorMessage(message)
            }
        }
    }

    private func sendCommitAndCreate() {
        let client = self.client
        Task {
            try? await client?.send(InputAudioBufferCommit())
            try? await client?.send(ResponseCreate(response: .init(
                modalities: ["audio", "text"]
            )))
        }
    }

    private func sendCancelAndClear() {
        let client = self.client
        Task {
            try? await client?.send(ResponseCancel())
            try? await client?.send(InputAudioBufferClear())
        }
    }
}
