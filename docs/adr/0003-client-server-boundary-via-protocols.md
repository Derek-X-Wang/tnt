# Client/server boundary expressed as Swift protocols

v0 has no server, but a server is in the long-term plan. To keep the eventual migration cheap, the **future server boundary is expressed today as Swift protocols**: any package whose v1 implementation will live on a remote `tnt-server` ships v0 as `protocol X { ... }` with a single in-process `LocalX` implementation. Packages that will permanently live on the client ship as concrete `final class` types with no protocol layer.

## What's behind a protocol (server-future)

- `protocol CognitiveEngine` — rewrite, summarize, prioritize, reflect, extract preferences. v0 impl `LocalOpenAIEngine` calls OpenAI directly from the client. v1 impl `RemoteEngine` will call `tnt-server` over HTTPS; the server orchestrates Hermes / pi-mono / OpenAI / whatever.
- `protocol MemoryStore` — preferences, corrections, agent registry, session history, user style. v0 impl `SQLiteMemoryStore` writes to `~/.tnt/memory.sqlite`. v1 impl `RemoteMemoryStore` syncs to server; server holds the durable user model.

## What's concrete (permanent client)

- `RealtimeWSClient` (TNTRealtime) — mic + WS to OpenAI Realtime. Audio bytes are not state; proxying adds latency without buying anything.
- `AccessibilityClient`, `HotkeyHost`, `MenuBarHost` (TNTPlatformMac) — OS resources, only the device can read them.
- `LocalIngestServer` (TNTIngest) — loopback HTTP for Worker Agent events. v0 lives in client. v1 may move to server, but the call sites that *consume* events are already behind `CognitiveEngine` / `MemoryStore` so the move is a transport swap, not a refactor of business logic.

## Why

The user explicitly framed the desired architecture as "intelligence on server, native client for OS access." v0 omits the server but keeps the architectural seam visible in the package layout. A future engineer reading the repo can answer "what would move to the server?" by listing every `protocol` in the codebase. Concrete classes are, by construction, the things that don't move.

## Considered alternatives

- **All concrete v0, refactor later** — fastest v0 but loses the architectural signal; reviewers and contributors won't see the boundary.
- **Protocol everywhere (also Voice, also Ingest, also Hotkey)** — premature; voice transport, ingest, and hotkeys are not server-future concerns and protocols there force boxing without benefit.

## Consequences

- v0 call sites depend on `CognitiveEngine` / `MemoryStore` protocols, never on the concrete `LocalOpenAIEngine` / `SQLiteMemoryStore` types. The single composition root in `TNTMac` is the only file that knows the v0 implementations exist.
- When `tnt-server` is built, only the implementations behind those two protocols change. UI, hotkeys, mic, ingest, and routing call sites stay byte-identical.
- BYOK key handling lives in the v0 `LocalOpenAIEngine`. When server arrives, the key moves server-side and `RemoteEngine` carries no secret. This is a deliberate migration path, not a forever solution.
