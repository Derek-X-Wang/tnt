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

    /// Count of mic frames forwarded since the current turn's `.startCapture`.
    /// Gates commit/`response.create`: GA `input_audio_buffer.commit` errors
    /// on an empty buffer, and `response.create` against no new user audio
    /// responds to stale context. Reset at each capture start.
    private var framesThisTurn = 0

    private weak var menuBarHost: MenuBarHost?
    private let apiKeyProvider: () throws -> String
    private let voice: String

    init(
        menuBarHost: MenuBarHost,
        apiKeyProvider: @escaping () throws -> String,
        voice: String = "marin"
    ) {
        self.menuBarHost = menuBarHost
        self.apiKeyProvider = apiKeyProvider
        self.voice = voice
        self.audio = RealtimeAudioSession()
    }

    // MARK: - Hotkey edges

    func startListening() async {
        TNTLog.voice.info("startListening: ensuring connection")
        await ensureConnection()
        guard client != nil else {
            TNTLog.voice.error("startListening: no client after ensureConnection — aborting (see prior error)")
            return
        }
        apply(flow.handle(.hotkeyStartListening))
    }

    func stopListening() async {
        TNTLog.voice.info("stopListening (\(self.framesThisTurn, privacy: .public) frames captured)")
        apply(flow.handle(.hotkeyStopListening))
        // The flow optimistically moves to .thinking on release. If capture
        // produced nothing (mic init failed, instant transport error, or an
        // ultra-fast tap) there's no committed audio, so no response will
        // arrive — reset to idle instead of hanging on the thinking lamp.
        if framesThisTurn == 0 {
            TNTLog.voice.info("stopListening: 0 frames — no response expected, resetting to idle")
            flow = VoiceTurnFlow()
            menuBarHost?.setState(.idle)
            menuBarHost?.setMicLevel(nil)
            audio.requestStopWhenDrained()
        }
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
            TNTLog.voice.info("ensureConnection: API key loaded (len=\(apiKey.count, privacy: .public))")
        } catch {
            TNTLog.voice.error("ensureConnection: API key missing — \(error.localizedDescription, privacy: .public)")
            menuBarHost?.setLastErrorMessage("OpenAI API key missing — Replace API Key…")
            return
        }

        let c = OpenAIRealtimeWSClient(apiKey: apiKey)
        do {
            TNTLog.voice.info("ensureConnection: connecting WS…")
            try await c.connect()
            TNTLog.voice.info("ensureConnection: WS connected")
        } catch {
            // Nothing to leak — `connect()` failed, so no live socket.
            TNTLog.voice.error("ensureConnection: WS connect FAILED — \(error.localizedDescription, privacy: .public)")
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
            var frameCount = 0
            for await frame in self.audio.frames {
                if Task.isCancelled { break }
                let dB = AudioLevel.peakDB(from: frame)
                let base64 = frame.base64EncodedString()
                try? await self.client?.send(InputAudioBufferAppend(audio: base64))
                self.menuBarHost?.setMicLevel(dB)
                self.framesThisTurn += 1
                frameCount += 1
                if frameCount == 1 || frameCount % 25 == 0 {
                    TNTLog.voice.info("captureDrain: forwarded \(frameCount, privacy: .public) mic frames (last peak \(dB, privacy: .public) dB)")
                }
            }
            TNTLog.voice.info("captureDrain: stream ended after \(frameCount, privacy: .public) frames")
        }
    }

    private func handle(serverEvent event: RealtimeServerEvent) {
        switch event {
        case .responseAudioDelta(let delta):
            apply(flow.handle(.audioDelta(delta.delta)))
        case .responseDone:
            TNTLog.voice.info("serverEvent: response.done")
            apply(flow.handle(.responseDone))
        case .error(let err):
            let summary = err.error.message ?? err.error.code ?? "Realtime error"
            TNTLog.voice.error("serverEvent: error — \(summary, privacy: .public)")
            apply(flow.handle(.responseError(summary)))
            // Drop the dead client so the next hotkey press reconnects.
            self.client = nil
        case .sessionCreated:
            TNTLog.voice.info("serverEvent: session.created")
            return
        case .unknown:
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
                    // Release the mic once the reply finishes playing, so
                    // the macOS mic-in-use indicator clears between turns.
                    audio.requestStopWhenDrained()
                }
            case .startCapture:
                framesThisTurn = 0
                do {
                    try audio.startCapture()
                    TNTLog.voice.info("startCapture: mic engine started, forwarding frames")
                } catch {
                    TNTLog.voice.error("startCapture FAILED — \(error.localizedDescription, privacy: .public)")
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
        guard framesThisTurn > 0 else {
            TNTLog.voice.error("sendCommitAndCreate: 0 frames captured — skipping commit/response.create (GA errors on an empty buffer)")
            return
        }
        let client = self.client
        Task {
            TNTLog.voice.info("sendCommitAndCreate: committing buffer + requesting response")
            try? await client?.send(InputAudioBufferCommit())
            try? await client?.send(ResponseCreate())
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
