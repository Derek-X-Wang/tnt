# Realtime transport: WebSocket, not WebRTC

`TNTRealtime` connects to OpenAI Realtime over WebSocket using `URLSessionWebSocketTask`. Audio capture is `AVAudioEngine` with `kAudioUnitSubType_VoiceProcessingIO` (built-in echo cancellation + AGC), encoded as PCM16 24kHz, framed and base64-wrapped into `input_audio_buffer.append` events. WebRTC was considered and rejected for v0.

## Why

WebSocket is a Foundation-only path with zero binary-size impact and full pipeline transparency — every event is printable, easy to log, easy to tee for bilingual/technical-terminology debugging. macOS's VoiceProcessingIO AudioUnit closes most of the audio-quality gap that WebRTC would otherwise win. WebRTC's real advantages (lower latency, jitter buffer, packet-loss concealment, Opus) cost ~30 MB of `WebRTC.xcframework` and an opaque audio pipeline that is harder to debug when speech recognition does something weird.

## Considered alternatives

- **WebRTC** — sounds better on flaky networks and gives ~100ms latency wins, but the +30 MB and opaque internals contradict "lightweight" and slow iteration on the bilingual + technical-terminology edge cases that are the actual MVP risk.
- **Defer / build both behind VoiceProvider protocol** — would ship two half-working pipelines instead of one solid one. Rejected by "do not overbuild."

## Consequences

- Echo, jitter, and barge-in are TNT's responsibility, not the framework's. We rely on `VoiceProcessingIO` for echo and write our own `response.cancel` + `input_audio_buffer.clear` flow for interruption.
- TCP head-of-line blocking is a known weakness on poor networks. Acceptable for desktop-on-wifi v0; revisit if telemetry shows real loss-related stalls.
- Re-evaluation trigger: if v0 telemetry shows perceptible latency complaints or iOS becomes the next platform, run a WebRTC spike behind the same `VoiceProvider` protocol.

## Status / amendments

- **2026-06 — VoiceProcessingIO dropped; plain HAL capture (issue #73).** The original decision used `kAudioUnitSubType_VoiceProcessingIO` for hardware echo cancellation + AGC. On hardware this had a disqualifying side effect: VPIO is a system "voice chat" unit that **ducks all other audio system-wide** for the entire time the engine is alive. Measured on the maintainer's Mac, with music/video playing: plain HAL capture = **other audio stays at full volume**; VPIO at `.min` ducking (the macOS 14 `voiceProcessingOtherAudioDuckingConfiguration` API) = **noticeably quieter**; VPIO default (what shipped) = **other audio goes SILENT**. A voice agent that silences the user's music every time they speak is unacceptable, and the `.min` ducking API reduces but cannot eliminate the duck.

  **Decision:** `TNTRealtime` now captures with a **plain HAL `AVAudioEngine` input node (no VPIO)**. What is lost is hardware echo cancellation + AGC. This is acceptable because TNT's Voice Turn is **sequential** (listen → think → speak): the mic is not open while the assistant's reply plays, so there is no acoustic echo path on the common turn. Echo cancellation only mattered for **barge-in on open speakers** (interrupting mid-reply while the reply plays out loud), a narrow case the Realtime **server-side VAD** tolerates; users on headphones (the assumed common case) have no acoustic path at all. If open-speaker barge-in echo proves to be a real problem in dogfooding, the follow-up is **software AEC** (e.g. webrtc-audio-processing) scoped to the speaking-while-listening window only — off the hot path — rather than re-adopting VPIO.

  **Verified by measurement, not assumption** (signed standalone harness, maintainer's hardware + ears): (1) plain HAL leaves other audio at full volume; (2) a single plain engine does simultaneous mic capture + speaker playback with no `-10875` / HALC-overload — the two-engines-fight-the-HAL failure this ADR's "Why one engine" reasoning warned about was specific to two *VPIO* full-duplex units, not one plain engine.

  **Not changed by this:** the single-engine design (one `AVAudioEngine` for both capture and playback) stands. And this does **not** fix the ~1.7s first-press-after-idle cold start — that is macOS mic-hardware wake, which plain HAL pays too; the only cure is keeping the mic device open (which lights the orange privacy indicator continuously, contra ADR-0004), so it is accepted for v0 and tracked in #73.
