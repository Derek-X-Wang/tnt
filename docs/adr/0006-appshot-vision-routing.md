# Appshot vision routing: Cognitive Engine answers, Realtime speaks

An **Appshot** (frontmost-window image + Window Text; see CONTEXT.md) needs a model that can *see* the image. TNT has two model surfaces: the **Realtime** model (speech↔speech over the WebSocket, ADR-0002) and the **Cognitive Engine** (shaped, persistence-aware thinking, ADR-0003). The decision: **a Voice Turn carrying Appshot(s) is reasoned about by the Cognitive Engine (a vision-capable model), and its answer is re-injected into the Realtime session so the Realtime model speaks it in one continuous voice.** The Realtime WebSocket stays audio-only; image bytes never ride it.

Both capture paths converge on a single Realtime **vision tool**. When the model calls it (because the user said "look at this", or because TNT injected "N appshots attached" into the session and the question needs vision), TNT resolves the source — armed Appshots if present, else a fresh frontmost-window grab — runs the Cognitive Engine vision route, and returns the answer text as the tool's `function_call_output`. The Realtime model continues from that result and speaks it.

## Why

- **Realtime is conversational, not the durable thinker.** CONTEXT.md already states "the Realtime model is NOT a Cognitive Engine." Vision reasoning over a captured window is exactly the "shaped thinking" the Cognitive Engine exists for; routing it there keeps the boundary in ADR-0003 honest rather than smuggling a second brain into the voice transport.
- **Avoids betting on an unverified API capability.** Feeding images into the Realtime session depends on the Realtime GA API accepting image input items — unverified, and ADR-0002 deliberately scoped the Realtime pipeline to PCM16 audio framing. Routing vision through the Cognitive Engine (a standard chat/responses call with image input) uses a capability we know exists.
- **One voice, conversational continuity.** Re-injecting the Cognitive answer via `function_call_output` means the Realtime model speaks it — same voice/prosody as the rest of the conversation, follow-ups stay in the same session, and the existing interrupt flow (`response.cancel`) still applies. A separate TTS call would diverge in voice and break continuity.
- **Reuses the seam already being built.** The function-call wiring (issue #30) and the `CognitiveEngine` protocol (M1) are on the path regardless. This decision makes #30 load-bearing for Appshot rather than introducing a new mechanism.

## Considered alternatives

- **Feed the image into the Realtime session** (same model sees + replies in voice). Lowest latency, single model, most "magical" — rejected for v0 because it depends on unverified GA image-input support and contradicts ADR-0002's audio-only Realtime scope. Re-evaluation trigger: if the Realtime GA API gains verified, low-friction image input, revisit — it would collapse two model calls into one.
- **Separate TTS, bypass Realtime.** Cognitive answer → standalone TTS → play directly. Decouples from #30, but risks a different voice than conversational turns and breaks interrupt + follow-up continuity (the answer lives outside the Realtime session). Rejected.
- **Always route every turn through the Cognitive Engine** (Realtime becomes a thin voice layer for all turns). Most uniform, but adds a Cognitive detour + latency to plain voice chat that M0 answers directly. Overreach for v0.

## Consequences

- Vision turns cost one extra model call (Cognitive Engine) before the spoken answer, so they are higher-latency than plain conversational turns. Acceptable: Appshot is an explicit "look at this" action, not the hot path.
- **Issue #30 (Realtime function-call wiring) is on the Appshot critical path.** Appshot (M4) cannot ship until tool calls + `function_call_output` round-trip works.
- The Cognitive Engine vision route needs the image + Window Text in its request shape — `LocalOpenAIEngine` gains a multimodal path using `cognitiveModel` (default gpt-5.2). The `CognitiveEngine` protocol grows a vision-capable method by M4.
- When `tnt-server` arrives (ADR-0003), vision routing moves server-side for free: it already lives behind the `CognitiveEngine` protocol, so only the implementation changes, not the Realtime call sites.
