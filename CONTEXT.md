# TNT

Voice-first personal master agent. Sits between a single human user and many AI agents (Claude Code, Cursor, OpenCode, future custom agents) and reduces the reading + cognitive load of running them in parallel.

## Language

### Product roles

**Personal Master Agent**:
The product surface itself. One per user. Mediates voice ↔ AI agents. Not a chatbot, not a dictation app, not a transcription tool.
_Avoid_: assistant, copilot, bot

**User**:
The single human owner of a TNT install. v0 is single-tenant by design.
_Avoid_: account, customer

**Worker Agent**:
An external AI agent that TNT talks _to_ on the user's behalf (Claude Code, Cursor, OpenCode, custom). TNT is _not_ a Worker Agent.
_Avoid_: subagent, child agent

### Architecture roles (v0)

**Desktop App**:
The single process that owns mic, hotkeys, TTS, UI, local memory, BYOK config, the WS to OpenAI Realtime, and the localhost ingest port. v0 has no remote server.
_Avoid_: client (no server exists v0)

**Local Ingest**:
The localhost endpoint inside Desktop App that receives Session Events from Worker Agents. Loopback-only. Default port TBD.
_Avoid_: webhook, callback

**BYOK Config**:
Local file (`~/.tnt/config` or similar) holding the user's OpenAI key and other provider secrets. Never leaves the device.
_Avoid_: credentials store, vault

### Interfaces

**Future Server Boundary**:
The line between "permanent client code" and "code whose v1 home is `tnt-server`." In the codebase, the boundary is visible: anything `protocol X { ... }` is destined for a server-side impl later; anything `final class` stays on device forever. v0 has no server — both sides of the boundary run in-process — but the seam is the migration path.
_Avoid_: backend boundary, API boundary

**Voice Provider** (concrete v0):
Mic + speech-to-speech transport. Permanent client. v0 = `RealtimeWSClient` talking to OpenAI Realtime over WebSocket. No protocol v0 — a 2nd voice provider is not on the v0 horizon and the protocol shape is unclear without one. Refactor to a protocol when a real 2nd impl ships.
_Avoid_: TTS engine, STT engine (those are sub-concerns)

**Cognitive Engine** (server-future):
Durable thinking layer: rewrite, summarize, prioritize, reflect, extract preferences. v0 ships `protocol CognitiveEngine` with one impl `LocalOpenAIEngine` (calls OpenAI directly from client). v1 impl will be `RemoteEngine` calling `tnt-server`, where Hermes / pi-mono / other engines compose. _Realtime model is NOT a Cognitive Engine_ — Realtime is conversational; Cognitive Engine is for shaped, persistence-aware thinking.
_Avoid_: brain, LLM (too generic)

**Memory Store** (server-future):
Durable user state. v0 ships `protocol MemoryStore` with one impl `SQLiteMemoryStore` at `~/.tnt/memory.sqlite` (GRDB.swift). v0 tables: `preferences`, `corrections`, `agents`, `session_events`, `vocabulary`. `session_events` auto-prune after 7 days; everything else is forever-retention until user wipes. v1 impl will be `RemoteMemoryStore` syncing to `tnt-server`.
_Avoid_: database, cache

**Executor** (concrete, permanent client):
The hands that perform a **Voice Action** on the OS. v0 ships the concrete `final class MacActionExecutor` (NSWorkspace + CGEvent + AX) — **not** behind a protocol. Its command set is a **closed enum** (`activateApp`, `focusWindow`, `pasteText`, `pressReturn`, later `type`, `keystroke`) — never a free-form `run(String)`. Like `HotkeyHost` and `AccessibilityClient`, it is **permanent client**: synthesizing input events needs local OS access and can never move to `tnt-server`. The **decider** of which action to perform is the **Cognitive Engine** (server-future — that is the seam that moves server-side later); the Executor only performs. The enum is the contract between decider and hands. See ADR-0007.
_Avoid_: driver, automation engine, robot

### Data shapes

**Session Event**:
A structured message a Worker Agent sends to Local Ingest via the `tnt` CLI. v0 types are exactly five: `started`, `stopped`, `summary`, `blocked`, `error`. Each type maps to a fixed spoken-priority rule (`blocked` and `error` interrupt at next idle; `summary` queues; `started`/`stopped` are silent). Anything outside the five types goes into the open `meta` dict on an existing type, never as a new top-level type.
_Avoid_: log line, notification

**Bilingual scope**:
v0 first-class language pair = English (en) + Mandarin Simplified (zh-Hans), with **code-switching inside a single Voice Turn** as a supported case ("这个 function should rate-limit 每个 IP"). Realtime is configured with both hints; Rewrite system prompts are bilingual-aware and default to English output for Worker Agents unless the user signals otherwise. Other languages still work but are not on the v0 test surface.

**Voice Turn**:
One round of human speech → TNT spoken reply. Spans the realtime session lifecycle. v0 starts/ends a Voice Turn via a single configurable hotkey (default ⌃⌥Space — ⌥Space collides with Raycast): _hold_ = push-to-talk, _tap_ = toggle until next tap. Wake-word activation is post-v0.
_Avoid_: utterance, message

**Appshot Hotkey**:
A second global hotkey (default ⌃⌥⇧Space, configurable) whose single press captures an **Appshot** of the current frontmost window and arms it into the pending **Capture Set** for the next Voice Turn. Unlike the voice hotkey it has no hold/tap distinction — one press, one capture. Distinct from the voice hotkey so grabbing context and speaking stay separate actions.
_Avoid_: screenshot key, capture key

**Rewrite**:
The transformation from messy bilingual rambling → clean Worker Agent prompt. Distinct from generic transcription.
_Avoid_: cleanup, fix, transcription (transcription is the pre-stage)

**Voice Action**:
A scoped OS action TNT performs on the user's behalf during a Voice Turn — "send it" (paste the Rewrite into the target Worker Agent + Return), "open Cursor", "focus the tnt window". The Realtime model invokes an executor tool live in the conversation; the **Executor** performs one action from a closed allowlist; TNT speaks a confirmation in the same voice. This is deliberately **not** Codex-style "Computer Use": TNT does not autonomously see-and-drive GUIs in a perceive→act→verify loop. The structural firewall: executor actions return **no screenshot** to the model, so it has no perception feedback to close a control loop with (only an **Appshot** returns vision). TNT stays the **Personal Master Agent** that mediates and performs narrow plumbing — it is not a GUI-puppeteering actor. See ADR-0007.
_Avoid_: Computer Use, GUI automation, agent action (those imply autonomous driving)

### Capture & privacy

**Capture Set**:
The bundle of context signals attached to a Voice Turn. v0 set: `app_name`, `window_title`, `selected_text`, `project_name`, `workspace_path`, and (on-demand only) `appshots` — zero or more **Appshots** of frontmost windows. Multiple Appshots stack into one turn (e.g. "compare this design to that spec"); both hotkey-armed and voice-pulled Appshots land in the same list. Pasteboard contents are deliberately excluded.
_Avoid_: context, payload, snapshot

**Appshot**:
A frontmost-window capture bundling two signals together: a window **image** (JPEG) and the window's **Window Text**. Captured on demand two ways — the user presses the **Appshot Hotkey** (arms it ahead of speaking), or, mid-Voice-Turn, the Realtime model invokes the single vision tool because the user said "look at this" / "can you see…". Either way the model engages vision through that one tool; TNT decides the source (armed Appshots if present, else a fresh frontmost-window grab). The image is reasoned about by the **Cognitive Engine** (vision-capable model), not the Realtime model. Held in memory for the duration of the Voice Turn, never written to disk by default. Requires the macOS Screen Recording TCC permission for the image and Accessibility for the Window Text. Named after the equivalent Codex feature.

An Appshot is a **self-contained context unit**: at capture time it freezes not just image + Window Text but also the source window's `app_name`, `window_title`, and `project` together. So an Appshot armed in Cursor stays labeled "Cursor" even if the user switches to another app before speaking. When an armed Appshot is present, its frozen context takes precedence; speak-time auto-capture only fills fields the Appshot did not freeze.
_Avoid_: screenshot, On-Demand Screenshot (superseded — Appshot is image **and** text), vision input, screen grab

**Window Text**:
The full text available from the frontmost window via the Accessibility API — visible text **and** text the app exposes outside the visible scroll area. One half of an Appshot. Distinct from **selected_text**, which is only the user's current highlight: Window Text is broad ("what does this whole error / email / settings panel say"), selected_text is a precise pointer ("improve _this_ function"). Both can be present in one Capture Set. Some apps (Google Docs, Gmail, Sheets, Slides) expose only the visible screenshot, not full off-screen text.
_Avoid_: page text, OCR text (it is AX-sourced, not OCR'd)

**Capture Chip**:
Menu-bar UI element that shows what context is currently attached (e.g. "📎 247 chars from Cursor", "📸 ×2 Cursor, Chrome"). Clickable to clear or preview. For an **Appshot** it must show the source app and a preview of the captured image **and Window Text** before the turn is sent — this pre-send visibility is what makes user-initiated Appshot capture privacy-defensible (the user sees exactly what's going to OpenAI). Exists so the user always knows what's about to be sent.
_Avoid_: badge, indicator

## Relationships

- A **User** owns one **Desktop App** install (v0).
- **Desktop App** speaks to one **Voice Provider** at a time and many **Worker Agents** (via Local Ingest) over time.
- A **Voice Turn** may produce a **Rewrite** that is then routed to a **Worker Agent**.
- A **Voice Turn** may produce a **Voice Action** that the **Executor** performs on the OS (e.g. pasting the Rewrite into the target **Worker Agent**).
- The **Cognitive Engine** decides _which_ **Voice Action** to take (v1 may plan a sequence); the **Executor** only performs it. The decider is server-future; the hands are permanent client.
- A **Worker Agent** emits **Session Events** to **Local Ingest**, which the **Cognitive Engine** can summarize and the **Voice Provider** can speak.
- **Memory Store** persists across **Voice Turns**; the **Voice Provider** session does not.

## Example dialogue

> **Dev**: "When the user finishes speaking, who turns the rambling into a clean Claude Code prompt — the Realtime model or a separate call?"
> **Product**: "It's a **Rewrite**. The **Voice Provider** captures the **Voice Turn**, but the rewriting itself is a **Cognitive Engine** concern — Realtime is for conversation, not durable shaping."
> **Dev**: "And if the rewrite needs to know which project the user is in?"
> **Product**: "That's context, captured by the **Desktop App** (active window, selected text) and passed into the rewrite prompt. The **Memory Store** holds preferences that bias the rewrite ('user prefers terse prompts')."

## Flagged ambiguities

- "agent" was overloaded between **Personal Master Agent** (TNT itself) and **Worker Agent** (Claude Code etc) — resolved: these are different roles, never refer to TNT as a worker or to Claude Code as the master.
- "memory" was used for both ephemeral conversation context and durable preferences — resolved: durable = **Memory Store**, ephemeral = **Voice Provider** session state, no overlap.
