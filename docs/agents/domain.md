# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Layout

This repo is **single-context**:

```
tnt/
├── CONTEXT.md
├── docs/
│   └── adr/
│       ├── 0001-desktop-only-v0-no-server.md
│       ├── 0002-realtime-transport-websocket.md
│       ├── 0003-client-server-boundary-via-protocols.md
│       ├── 0004-privacy-posture-v0.md
│       └── 0005-distribution-and-updates.md
└── …
```

There is no `CONTEXT-MAP.md`. If one ever appears, it means the repo split into multiple contexts (e.g. `apps/swift` vs a future `tnt-server`); each context will then carry its own `CONTEXT.md` and own `docs/adr/`.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root.
- **`docs/adr/`** — read ADRs that touch the area you're about to work in.

If any of these files don't exist for a given concept, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The producer skill (`/grill-with-docs`) creates them lazily when terms or decisions actually get resolved.

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `CONTEXT.md`. Don't drift to synonyms the glossary explicitly marks `_Avoid_:`.

If the concept you need isn't in the glossary yet, that's a signal — either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/grill-with-docs`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0003 (client/server boundary via protocols) — but worth reopening because…_
