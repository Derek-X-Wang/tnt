// VoiceTurnController — glue layer that runs one **Voice Turn** by
// coordinating `AudioCapture`, `OpenAIRealtimeWSClient`,
// `AudioOutputPlayer`, and `MenuBarHost` against a pure
// `VoiceTurnFlow` state machine. Lives in the app target so it can
// import every package the v0 voice path touches.
//
// The state-transition logic itself is in `TNTPlatformMac.VoiceTurnFlow`
// and unit-tested there; this class is the thinnest possible bridge
// between the flow's directives and the actual hardware / network.

import AppKit
import Foundation
import TNTCore
import TNTPlatformMac
import TNTRealtime

@MainActor
final class VoiceTurnController {

    private var flow = VoiceTurnFlow()
    private let capture: VoiceProcessingIOAudioCapture
    private let player: AudioOutputPlayer
    private var client: OpenAIRealtimeWSClient?

    private var captureTask: Task<Void, Never>?
    private var inboundTask: Task<Void, Never>?

    private weak var menuBarHost: MenuBarHost?
    private let apiKeyProvider: () throws -> String

    init(menuBarHost: MenuBarHost, apiKeyProvider: @escaping () throws -> String) {
        self.menuBarHost = menuBarHost
        self.apiKeyProvider = apiKeyProvider
        self.capture = VoiceProcessingIOAudioCapture()
        self.player = AudioOutputPlayer()
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
        captureTask?.cancel()
        inboundTask?.cancel()
        await capture.stop()
        player.stop()
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
            try player.start()
        } catch {
            menuBarHost?.setLastErrorMessage("Could not connect: \(error.localizedDescription)")
            return
        }

        self.client = c
        menuBarHost?.setLastErrorMessage(nil)
        startInboundDrain(on: c)
    }

    private func startInboundDrain(on client: OpenAIRealtimeWSClient) {
        let stream = client.inbound
        inboundTask = Task { [weak self] in
            for await event in stream {
                if Task.isCancelled { break }
                await MainActor.run {
                    self?.handle(serverEvent: event)
                }
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
                startCaptureForwarding()
            case .stopCapture:
                stopCaptureForwarding()
            case .sendCommitAndCreate:
                sendCommitAndCreate()
            case .sendCancelAndClear:
                sendCancelAndClear()
            case .enqueuePlayback(let payload):
                player.enqueueBase64(payload)
            case .stopPlayer:
                player.stop()
            case .restartPlayer:
                try? player.start()
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

    private func startCaptureForwarding() {
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.capture.start()
            } catch {
                await MainActor.run {
                    self.menuBarHost?.setLastErrorMessage("Mic start failed: \(error.localizedDescription)")
                }
                return
            }
            for await frame in self.capture.frames {
                if Task.isCancelled { break }
                let dB = AudioLevel.peakDB(from: frame)
                let base64 = frame.base64EncodedString()
                let client = await MainActor.run { self.client }
                try? await client?.send(InputAudioBufferAppend(audio: base64))
                await MainActor.run {
                    self.menuBarHost?.setMicLevel(dB)
                }
            }
        }
    }

    private func stopCaptureForwarding() {
        captureTask?.cancel()
        captureTask = nil
        Task { [capture] in
            await capture.stop()
        }
    }
}
