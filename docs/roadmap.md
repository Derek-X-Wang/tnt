# Roadmap — v0 milestones

v0 = M0 + M1 + M2 + M3 stable. M4 is a stretch goal that can land in v0 if time allows, otherwise v0.1.

Each milestone is independently shippable through the Sparkle auto-update channel — dogfood users get every milestone the moment it lands.

---

## M0 — Voice round-trip works

**Acceptance demo**
Hold `⌃⌥Space`, say "Hi, can you hear me?" or "你好，能听到吗？". Hear a Realtime spoken reply within ~600ms of release. Tap-toggle alternates open/closed mic. Menu bar reflects mic state.

**Ships**
- Signed + notarized `.dmg` via GitHub Releases (mirroring `ContextFS/ctxfs` pipeline).
- Sparkle auto-update wired against an `appcast.xml` on GitHub Pages.
- Menu-bar app skeleton with state lamp (`idle | listening | thinking | speaking`).
- First-run privacy consent screen + Microphone + Input Monitoring TCC prompts.
- BYOK config reader at `~/.tnt/config` (OpenAI key, optional Realtime model override).
- `RealtimeWSClient` in `TNTRealtime` (URLSessionWebSocketTask, AVAudioEngine PCM16 24 kHz, VoiceProcessingIO echo cancellation, `response.cancel` interrupt).
- Hotkey listener in `TNTPlatformMac` (default `⌃⌥Space`, configurable via UserDefaults).
- Bilingual hint config: `language: ["en", "zh"]` on Realtime session.

**Out of scope**
- No Cognitive Engine. No Memory. No Worker Agents. No context capture.

---

## M1 — Rewrite to Worker Agent prompt

**Acceptance demo**
Speak: "啊，给 Claude Code 一个指令，让它在 rate-limit middleware 里加一个 unit test，要 mock 那个 bucket，然后 cover 三种 timeout 情况." TNT speaks back: "I'll send: 'Add a unit test to the rate-limit middleware…' — confirm?" User: "yes." TNT copies the clean prompt to clipboard, plays a confirmation chime, fires a system notification.

**Ships**
- `protocol CognitiveEngine` + `LocalOpenAIEngine` impl in `TNTCognitive`.
- Realtime tool `compose_agent_prompt(target, intent, raw_transcript)` wired to call CognitiveEngine.
- Capture Set v0: `app_name`, `window_title`, `selected_text`, `project_name`, `workspace_path` via Accessibility API in `TNTPlatformMac`.
- Capture Chip in menu bar (clickable, clearable, previewable).
- Pasteboard write + system notification on confirmation.
- Bilingual-aware Rewrite system prompt with few-shot zh-en examples.

**Out of scope**
- No Worker Agent ingest (next milestone).
- No memory of past Rewrites.

---

## M2 — Worker Agent integration (Claude Code first)

**Acceptance demo**
Wire Claude Code hooks per `docs/integrations/claude-code.md`. Run a long Claude Code task. On `Stop` hook, `tnt event summary --message "Tests pass, README updated"` fires. TNT (idle) speaks: "Claude Code finished: tests pass, README updated." Mid-task, an error fires `tnt event blocked --message "Needs clarification on auth flow"` — TNT interrupts current state at next idle to announce. Later, the user asks: "What's pending?" — TNT summarizes active blocked/error events across agents.

**Ships**
- `TNTIngest`: loopback HTTP server on `127.0.0.1:<port>`, ingest token at `~/.tnt/ingest-token`, `POST /ingest` accepting the v0 5-type Session Event schema.
- `tnt` Swift CLI binary as a target inside `apps/swift/TNTCLI/`. Symlinked into PATH on first launch (with user consent prompt). Verbs: `event started|stopped|summary|blocked|error|...`, `vocab add|list|remove`, `pref get|set`.
- `TNTMemory`: SQLite + GRDB migrations for `agents`, `session_events`. 7-day prune job for events.
- Spoken-priority routing: `blocked`/`error` interrupt at next idle moment; `summary` queues; `started`/`stopped` are silent.
- Realtime tool `whats_pending()` → CognitiveEngine summary over recent events.
- One-time per-agent consent dialog on first ingest from a new agent name.
- `docs/integrations/claude-code.md` + `examples/hooks/claude-code.json`.

**Out of scope**
- Cursor / OpenCode integration docs come in v0.x once Claude Code is solid.

---

## M3 — Personalization

**Acceptance demo**
Use TNT for a few days. Tell it: "When you talk to Claude Code on this repo, prefer terse prompts, no preamble." TNT remembers (project-scoped). Next Rewrite reflects the preference. Correct a misheard term: "no, not 'rate limit', 'rake task'" — future transcriptions bias correctly.

**Ships**
- `preferences`, `corrections`, `vocabulary` tables wired in `TNTMemory`.
- Rewrite system prompt incorporates relevant preferences (global + project + agent scope).
- Realtime session config seeds vocabulary as bias terms.
- `tnt vocab add`, `tnt pref set` CLI verbs.
- Voice-driven correction capture: when user says a correction-shaped utterance ("no I meant X"), CognitiveEngine extracts the (raw, fixed) pair and persists.

**Out of scope**
- No reflection / self-summarization loops yet (post-v0 Hermes integration territory).

---

## M4 — On-demand screenshots (stretch / v0.1)

**Acceptance demo**
With Cursor open showing a confusing diagram, user says: "Look at this and tell me what the data flow is." Realtime calls `capture_screen()`, frontmost-window JPEG goes to a vision-capable Cognitive Engine model, TNT replies: "It looks like…"

**Ships**
- ScreenCaptureKit integration in `TNTPlatformMac` (frontmost window only).
- Screen Recording TCC permission prompt on first capture.
- Multimodal route in `LocalOpenAIEngine` (vision-capable model for the screenshot path).
- Capture Chip shows screenshot thumbnail; clearable.
- In-memory only, JPEG quality 80, never written to disk by default.

---

## Beyond v0

- Cursor + OpenCode integration docs.
- Wake-word activation behind a setting.
- iOS app target activation (most `Packages/` already work; only `TNTPlatformMac` is gated to macOS).
- MCP server transport for Worker Agents that prefer it.
- `tnt-server`: durable brain. `RemoteEngine` + `RemoteMemoryStore` impls of the existing protocols. Multi-device sync.
- Cognitive Engine swap-ins: HermesEngine, PiEngine, LocalLLMEngine.
- Permissioned execution layer (Executor / MCP-style) — TNT routes commands _to_ agents, not just receives events from them.
