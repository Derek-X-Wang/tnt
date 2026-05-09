# Privacy posture v0

TNT v0 ships with a privacy posture intended for an OSS personal-master-agent: the only outbound network destination is OpenAI (via the user's BYOK key); nothing else phones home. Local persistence of Voice Turn audio and transcripts is **off by default** and opt-in. Context capture (selected text, screenshots, project paths) is always visible to the user via the Capture Chip in the menu bar, and a "Pause capture" master switch one-click disables it. First launch shows a mandatory consent screen explaining all of the above before any mic activation.

## Defaults

- **No telemetry, no analytics, no crash reports** in v0. The codebase contains no third-party telemetry SDKs; CI lints for accidental introduction.
- **OpenAI Zero Data Retention (ZDR)** request header is set on every Realtime + Cognitive Engine call. No-op if the user's org doesn't have ZDR; ensures we don't leak the option for orgs that do.
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
