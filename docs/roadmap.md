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

## M4 — Appshots (stretch / v0.1)

An **Appshot** sends the frontmost app window — **image + Window Text** — into a Voice Turn so TNT can answer questions about what's on screen. Modeled on the Codex Appshots feature. Depends on M1 (Capture Set, `CognitiveEngine`, the Realtime function-call wiring in #30) and M3 (the Cognitive Engine work the vision route extends). See ADR-0006 (Appshot vision routing) and the ADR-0004 amendment (user-initiated capture privacy).

**Acceptance demo**
With Cursor open showing an error, the user presses the **Appshot Hotkey** (⌃⌥⇧Space) — the Capture Chip shows "📸 Cursor armed". The user then holds ⌥Space and asks "what's causing this?". The Realtime model calls the vision tool; TNT routes the armed Appshot (image + Window Text) + transcript to the vision-capable Cognitive Engine; the answer is re-injected into the Realtime session and spoken in one voice. The hands-free path also works: with no Appshot armed, the user says "look at this and tell me the data flow" and the model calls the same tool, capturing the frontmost window fresh.

**Ships**
- **Appshot Hotkey** (default ⌃⌥⇧Space, configurable) in `TNTPlatformMac` — single press captures + arms an Appshot. Reuses `HotkeyChord` (no hold/tap recognizer).
- **Appshot** as a frozen, self-contained context unit in `TNTCore`: `image` (JPEG) + `windowText` + the source window's `appName`/`windowTitle`/`project`, captured together. Capture Set holds `appshots: [Appshot]` (stacking supported).
- **ScreenCaptureKit** integration in `TNTPlatformMac` (frontmost window image only).
- **Window Text** capture via Accessibility API (visible + off-screen available text) in `TNTPlatformMac`. Google Docs/Gmail/Sheets/Slides may yield image-only.
- **Single vision tool** in the Realtime session config; TNT resolves the source (armed Appshots if present, else fresh frontmost grab). When Appshots are armed, TNT injects "N appshots attached" into the session so the model knows vision is available.
- **Vision route** in `LocalOpenAIEngine` (`CognitiveEngine`): transcript + appshot image(s) + Window Text → vision-capable model (`cognitiveModel`, default gpt-5.2) → answer text → re-injected into Realtime via `function_call_output` (#30) so the Realtime model speaks it.
- **JIT permissions**: Screen Recording (image) and Accessibility (Window Text) requested on first Appshot, not at first launch. First-run consent screen still names all three up front.
- **Capture Chip** shows source app + image thumbnail **and** a Window-Text preview before send; clearable (all or last).
- In-memory only, JPEG quality 80, never written to disk by default.

---

## M5 — Voice Actions (stretch / v0.x)

A **Voice Action** turns voice into a scoped OS action TNT performs itself — "send it" (paste the Rewrite into the target Worker Agent + Return), "open Cursor", "focus the tnt window". Deliberately **not** Codex-style Computer Use: a closed allowlist, no autonomous perceive→act→verify loop. Depends on M1 (Capture Set, `CognitiveEngine`, target-app capture) + the Realtime function-call wiring (#30). See ADR-0007.

**Acceptance demo**
After a Rewrite, instead of ⌘V-ing manually, the user says "send it to Claude Code." The Realtime model calls an executor tool; TNT verifies Claude Code is the bound target and still frontmost, pastes the Rewrite, presses Return, and speaks "Sent." in one voice. "Open Cursor" / "focus the tnt window" just happen and TNT says what it did.

**Ships**
- `final class MacActionExecutor` in `TNTPlatformMac` (NSWorkspace + CGEvent + AX) over a **closed enum** — `activateApp`, `focusWindow`, `pasteText`, `pressReturn`. Never `run(String)`.
- Executor tools in the Realtime session; results re-injected via `function_call_output` (#30) so the model speaks the outcome.
- **Target binding + verify**: the action's target (bundle ID + window) is captured at tool-call time and re-checked immediately before acting; mismatch aborts with `target_changed` and offers to focus first (focus-race guard, same bug class as #27).
- **Confirmation by blast radius**: reversible actions (`activateApp`, `focusWindow`) just happen; irreversible/exfiltrating ones (`pasteText`, `pressReturn`) get one spoken confirm per turn. Never per-keystroke.
- **No perception feedback**: executor results return status only (`done` / `needs_confirmation` / `target_changed` / `permission_missing` / `unsupported`), never a screenshot — the structural firewall against the allowlist drifting into puppeteering.
- First action = **"send the Rewrite,"** closing the M1 clipboard-handoff gap.

**Out of scope**
- `type(String)` / `keystroke` (highest-risk verbs) — added only after the target guard is proven, behind the confirm tier.
- Autonomous GUI driving (perceive→act→verify, open-ended task completion) — stays Beyond v0.

---

## Beyond v0

- Cursor + OpenCode integration docs.
- Wake-word activation behind a setting.
- iOS app target activation (most `Packages/` already work; only `TNTPlatformMac` is gated to macOS).
- MCP server transport for Worker Agents that prefer it.
- `tnt-server`: durable brain. `RemoteEngine` + `RemoteMemoryStore` impls of the existing protocols. Multi-device sync.
- Cognitive Engine swap-ins: HermesEngine, PiEngine, LocalLLMEngine.
- Autonomous Computer Use — TNT drives GUIs in a perceive→act→verify loop for open-ended task completion (beyond the M5 narrow **Voice Action** allowlist), grown by letting the **Cognitive Engine** perceive via **Appshot** between **Executor** actions (ADR-0007 decision 3), never by making the executor smart.
- `WorkerAgentDispatcher` — permissioned command-routing _to_ Worker Agents over app-native/agent-native channels (CLI / MCP / deep link), preferred over GUI driving when a structured channel exists. TNT routes commands _to_ agents, not just receives events from them.
