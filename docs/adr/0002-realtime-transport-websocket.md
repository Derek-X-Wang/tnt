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
