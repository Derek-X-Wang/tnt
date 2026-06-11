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
//
// Outbound event ordering (issue #27): ALL sends go through
// `sendQueue` (`RealtimeSendQueue`). Mic-frame appends and commit/
// response.create share the same serialized actor channel, so no
// append from a turn can land after that turn's commit.

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

    /// Convenience accessor to the client's serialized send queue.
    /// All outbound events (appends, commit, create, cancel, clear)
    /// go through this queue. Nil when no client is connected.
    private var sendQueue: RealtimeSendQueue? { client?.sendQueue }

    private var captureDrainTask: Task<Void, Never>?
    private var inboundTask: Task<Void, Never>?

    /// Count of mic frames forwarded since the current turn's `.startCapture`.
    /// Gates commit/`response.create`: GA `input_audio_buffer.commit` errors
    /// on an empty buffer, and `response.create` against no new user audio
    /// responds to stale context. Reset at each capture start.
    private var framesThisTurn = 0

    /// True while a compose tool-call round-trip is in flight — from dispatch
    /// until the spoken-confirm `response.done` fires `.confirmationProduced`.
    /// While true, `response.done` is routed to the orchestrator, not the flow,
    /// so the earlier function-call `response.done` doesn't reset the turn.
    private var composeInFlight = false

    /// Serialized outbound tail: each `serialSend` awaits the previous so
    /// ordering holds (a `function_call_output` MUST precede its `response.create`).
    private var outboundTail: Task<Void, Never>?

    private weak var menuBarHost: MenuBarHost?
    private let apiKeyProvider: () throws -> String
    private let voice: String

    /// Injected Cognitive Engine compose closure. The concrete `LocalOpenAIEngine`
    /// is constructed only at the composition root (TNTMacApp), per ADR-0003; that
    /// closure also re-reads the BYOK key per call so a replaced key takes effect.
    private let composeFunc: (AgentRef, String, String, CaptureSet) async throws -> String

    /// Performs the confirmed-Rewrite delivery effects (pasteboard write, chime,
    /// notification). Constructed with real OS sinks at the composition root (#51).
    private let promptDeliverer: PromptDeliverer

    /// The Capture Set attached to the next Voice Turn, mirrored to the menu
    /// bar's Capture Chip (#52). Stays `.empty` until live AX capture lands
    /// (#49); the user can clear it from the chip at any time, which
    /// suppresses context for the next turn.
    private(set) var attachedCapture: CaptureSet = .empty

    /// Pure compose round-trip policy (issue #79). Lazy so its self-capturing
    /// send/event hooks can reference `self` after init completes.
    private lazy var composeOrchestrator = ComposeOrchestrator(
        compose: composeFunc,
        sendFunctionCallOutput: { [weak self] callId, output in
            self?.serialSend(ConversationItemCreateFunctionOutput(callId: callId, output: output))
        },
        sendResponseCreate: { [weak self] in
            self?.serialSend(ResponseCreate())
        },
        onEvent: { [weak self] event in
            Task { @MainActor in self?.handleOrchestratorEvent(event) }
        }
    )

    init(
        menuBarHost: MenuBarHost,
        apiKeyProvider: @escaping () throws -> String,
        voice: String = "marin",
        compose: @escaping (AgentRef, String, String, CaptureSet) async throws -> String,
        promptDeliverer: PromptDeliverer
    ) {
        self.menuBarHost = menuBarHost
        self.apiKeyProvider = apiKeyProvider
        self.voice = voice
        self.composeFunc = compose
        self.promptDeliverer = promptDeliverer
        self.audio = RealtimeAudioSession()
    }

    // MARK: - Capture Set (#52)

    /// Attach a Capture Set to the next Voice Turn and reflect it on the
    /// Capture Chip. Called by the capture path (#49) at turn-start.
    func setAttachedCapture(_ capture: CaptureSet) {
        attachedCapture = capture
        menuBarHost?.setCaptureSet(capture)
    }

    /// Clear the attached context (Capture Chip "Clear Context" action).
    /// The next Voice Turn goes out with no Capture Set until re-captured.
    func clearAttachedCapture() {
        setAttachedCapture(.empty)
    }

    // MARK: - Pre-warm

    /// Warm the audio device at launch so the user's first Voice Turn resumes
    /// fast instead of paying the ~1.5s device cold-open (issue #73). Runs the
    /// blocking start off the main actor. Caller gates on mic-granted + the
    /// PrewarmSetting toggle.
    func prewarmAudio() {
        let audio = self.audio
        Task.detached(priority: .utility) {
            audio.prewarm()
        }
    }

    // MARK: - Hotkey edges

    func startListening() async {
        TNTLog.voice.info("startListening: ensuring connection")
        await ensureConnection()
        guard client != nil else {
            TNTLog.voice.error("startListening: no client after ensureConnection — aborting (see prior error)")
            return
        }
        // New Voice Turn: advance the orchestrator's turn-generation token so any
        // in-flight compose for the previous turn is dropped on completion.
        composeOrchestrator.advanceTurnToken()
        composeInFlight = false
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
        outboundTail?.cancel()
        captureDrainTask = nil
        inboundTask = nil
        audio.stop()
        if let client {
            await client.disconnect()
        }
        client = nil
        // sendQueue is a computed var (client?.sendQueue), so clearing
        // client implicitly clears the queue reference.
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
        // voice + system prompt aligned. Routed through sendQueue so
        // the session.update is serialized with all subsequent sends.
        do {
            // Register the M1 Rewrite tools on every connect so the model can
            // call compose_agent_prompt / deliver_prompt. withRewriteTools()
            // returns a Body, so re-wrap it in a SessionUpdate.
            let body = SessionUpdate.bilingualV0(voice: voice).session.withRewriteTools()
            try await c.sendQueue.send(SessionUpdate(session: body))
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
    ///
    /// Appends go through `sendQueue.sendAppend()` rather than the
    /// client's `send()` directly — this is the producer side of the
    /// ordering guarantee. `sendCommitAndCreate` calls `drain()` on
    /// the same queue before commit, ensuring all appends arrive first.
    private func startCaptureDrain() {
        guard captureDrainTask == nil else { return }
        captureDrainTask = Task { [weak self] in
            guard let self else { return }
            var frameCount = 0
            for await frame in self.audio.frames {
                if Task.isCancelled { break }
                let dB = AudioLevel.peakDB(from: frame)
                let base64 = frame.base64EncodedString()
                // Increment before the sendAppend await so that a hotkey
                // release while the first frame is suspended sees
                // framesThisTurn > 0 and does not skip the commit.
                // This is the framesThisTurn race fix from issue #66:
                // count issued frames (pre-await), not sent frames (post-await).
                self.framesThisTurn += 1
                try? await self.sendQueue?.sendAppend(InputAudioBufferAppend(audio: base64))
                self.menuBarHost?.setMicLevel(dB)
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
        case .responseDone(let done):
            if composeInFlight {
                // Consumed by the orchestrator: it fires .confirmationProduced on
                // the spoken-confirm response.done. Routing to the flow here would
                // prematurely reset the turn on the earlier function-call done.
                composeOrchestrator.handleResponseDone(responseId: done.responseId, status: done.status)
            } else {
                TNTLog.voice.info("serverEvent: response.done")
                apply(flow.handle(.responseDone))
            }
        case .error(let err):
            let summary = err.error.message ?? err.error.code ?? "Realtime error"
            TNTLog.voice.error("serverEvent: error — \(summary, privacy: .public)")
            composeInFlight = false
            apply(flow.handle(.responseError(summary)))
            // Drop the dead client so the next hotkey press reconnects.
            self.client = nil
        case .sessionCreated:
            TNTLog.voice.info("serverEvent: session.created")
            return
        case .functionCallArgumentsDone(let callId, let name, let argumentsJSON):
            handleToolCall(callId: callId, name: name, argumentsJSON: argumentsJSON)
        case .unknown:
            return
        }
    }

    // MARK: - Tool-call dispatch (M1)

    /// Dispatch a Realtime function-call to the compose/deliver path. Decoding
    /// and policy live in the pure, tested TNTPlatformMac cores (ToolCallDispatch
    /// #78, ComposeOrchestrator #79); this is the thin app-target glue that
    /// injects the real network (compose) and send hooks.
    private func handleToolCall(callId: String, name: String, argumentsJSON: String) {
        let decision = classifyToolCall(name: name, argumentsJSON: argumentsJSON)
        switch decision {
        case .compose:
            TNTLog.voice.info("toolCall: compose_agent_prompt — dispatching to Cognitive Engine")
            composeInFlight = true
            Task { @MainActor in
                // Attached capture is .empty until live AX capture lands (#49);
                // the chip's Clear action also resets it to .empty.
                await self.composeOrchestrator.handleDecision(decision, callId: callId, capture: self.attachedCapture)
            }
        case .deliver:
            // The model heard an affirmation and called deliver_prompt. Drive the
            // flow's exactly-once handshake: .userAffirmed emits .deliverRewrite
            // (handled in apply → PromptDeliverer) and returns to idle. Ack the
            // tool call with a function_call_output so the Realtime turn doesn't
            // hang; deliberately NO response.create — chime + notification are the
            // confirmation, and a fresh response would land its audio in .idle
            // (dropped). deliver_prompt carries no payload (no injection path).
            TNTLog.voice.info("toolCall: deliver_prompt — affirming + delivering pending Rewrite")
            apply(flow.handle(.userAffirmed))
            serialSend(ConversationItemCreateFunctionOutput(callId: callId, output: "delivered"))
        case .ignore:
            TNTLog.voice.info("toolCall: \(name, privacy: .public) ignored (unknown tool or undecodable args)")
        }
    }

    /// Apply an event emitted by the compose orchestrator to the flow.
    private func handleOrchestratorEvent(_ event: ComposeOrchestratorEvent) {
        switch event {
        case .confirmationProduced(let rewrite):
            composeInFlight = false
            TNTLog.voice.info("orchestrator: confirmationProduced — entering confirming state")
            apply(flow.handle(.confirmationProduced(pendingRewrite: rewrite)))
        }
    }

    /// Serialized outbound send. Each call awaits the previous so the order the
    /// orchestrator emits hooks in is preserved on the wire — a
    /// `function_call_output` is always sent before its `response.create`.
    private func serialSend<E: Encodable & Sendable>(_ event: E) {
        let queue = self.sendQueue
        let prev = outboundTail
        outboundTail = Task { @MainActor in
            await prev?.value
            try? await queue?.send(event)
        }
    }

    // MARK: - Directive execution

    private func apply(_ directives: [VoiceTurnDirective]) {
        for directive in directives {
            switch directive {
            case .setState(let state):
                menuBarHost?.setState(state)
                // Release the mic (pause, stay warm) on any non-capturing resting
                // state so the macOS mic indicator clears. `.idle` between turns,
                // and `.confirming` — a resting state holding the pending Rewrite
                // where the tap is already removed but the device would otherwise
                // stay open (dot lit) until the user holds to affirm. The next
                // hold resumes warm (~120ms), so dropping the device here is free.
                switch state {
                case .idle, .confirming:
                    menuBarHost?.setMicLevel(nil)
                    audio.requestStopWhenDrained()
                default:
                    break
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
            case .deliverRewrite(let rewrite):
                // Confirmed Rewrite — perform the delivery effects exactly once:
                // pasteboard write + chime + notification. The flow already cleared
                // its pendingRewrite when it emitted this directive, so a stray
                // second userAffirmed is a no-op (exactly-once at the flow layer).
                TNTLog.voice.info("deliverRewrite: delivering confirmed Rewrite (len=\(rewrite.count, privacy: .public))")
                promptDeliverer.deliver(rewrite)
            }
        }
    }

    private func sendCommitAndCreate() {
        guard framesThisTurn > 0 else {
            TNTLog.voice.error("sendCommitAndCreate: 0 frames captured — skipping commit/response.create (GA errors on an empty buffer)")
            return
        }
        let queue = self.sendQueue
        Task {
            // drain() ensures every input_audio_buffer.append for this
            // turn has been written to the transport before the commit
            // fires. Because drain() and all sendAppend() calls share
            // the same actor mailbox (FIFO), drain() only executes
            // after every preceding append has completed — this is the
            // fix for the ordering race described in issue #27.
            await queue?.drain()
            TNTLog.voice.info("sendCommitAndCreate: drain complete — committing buffer + requesting response")
            try? await queue?.send(InputAudioBufferCommit())
            try? await queue?.send(ResponseCreate())
        }
    }

    private func sendCancelAndClear() {
        let queue = self.sendQueue
        Task {
            try? await queue?.send(ResponseCancel())
            try? await queue?.send(InputAudioBufferClear())
        }
    }
}
