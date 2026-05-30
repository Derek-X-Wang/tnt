# Privacy posture v0

TNT v0 ships with a privacy posture intended for an OSS personal-master-agent: the only outbound network destination is OpenAI (via the user's BYOK key); nothing else phones home. Local persistence of Voice Turn audio and transcripts is **off by default** and opt-in. Context capture (selected text, screenshots, project paths) is always visible to the user via the Capture Chip in the menu bar, and a "Pause capture" master switch one-click disables it. First launch shows a mandatory consent screen explaining all of the above before any mic activation.

## Defaults

- **No telemetry, no analytics, no crash reports** in v0. The codebase contains no third-party telemetry SDKs; CI lints for accidental introduction.
- **OpenAI Zero Data Retention (ZDR)** — _superseded, see note below._ The original intent was a per-connection `OpenAI-Realtime-Zero-Data-Retention` request header on every Realtime call. The Realtime **GA** API (`/v1/realtime`) removed that beta header; ZDR is now configured at the org/project level rather than per request. The client therefore no longer asserts ZDR on the wire. Wiring the GA ZDR mechanism is tracked separately (see "Status / amendments").
- **Voice Turn audio + transcripts**: in-memory only. Discarded when the turn ends. Opt-in via `defaults write com.tnt.app log_sessions true` writes to `~/.tnt/sessions/<date>/<turn-id>/`.
- **Memory Store** (SQLite) stays at `~/.tnt/memory.sqlite`; never leaves the device v0. Menu bar offers "Export" (encrypted JSON) and "Wipe."
- **Worker Agent transcripts** ingested via the `tnt` CLI flow through Cognitive Engine (which goes to OpenAI). First time a new agent's hook fires, TNT shows a one-time consent dialog naming the agent and the data shape; preference is persisted in MemoryStore.
- **Pasteboard** is **never** read for context — too easy to accidentally exfiltrate copied secrets (1Password, banking, chat).

## Why

OSS personal-master-agent trust hinges on a clean privacy story. Users will read the README before granting Accessibility + Microphone + Screen Recording permissions; the README must defensibly say "the only outbound destination is your own OpenAI account, and we show you what you're sending before we send it." Local logging on-by-default would invert that promise for users on shared machines. Telemetry on-by-default would invert it for everyone.

## Consequences

- Debugging field issues without logs is harder. Users who hit problems must be guided to enable opt-in logging and re-run.
- Worker Agent integration must include a consent step in the documented setup flow, not just a hook config snippet.
- Future hosted-server v1 inherits this posture: server can hold ZDR-enabled keys, but the consent + capture-chip UX remains client-side.

## Status / amendments

- **2026-05-29 — ZDR header retired (Realtime GA migration).** OpenAI removed the Realtime Beta API, and with it the per-connection `OpenAI-Realtime-Zero-Data-Retention` header this ADR originally specified. The client now connects to GA `/v1/realtime` with Bearer auth only. ZDR for GA is an org/project-level setting, not a request header, so the "set on every call" default above no longer holds at the wire level. Re-establishing a defensible ZDR guarantee on the GA surface is tracked as a follow-up issue. The rest of the privacy posture (no telemetry, in-memory turns, pasteboard exclusion, consent screen) is unchanged.
