# AGENTS.md

Canonical instruction set for AI agents working in the TNT repo. `CLAUDE.md` symlinks to this file so Claude Code, Codex, Cursor, Aider, and other tools all read the same source of truth.

## What is TNT

Voice-first personal master agent. See [CONTEXT.md](./CONTEXT.md) for domain language and [docs/roadmap.md](./docs/roadmap.md) for v0 milestones.

## Project conventions

- **Domain language**: [CONTEXT.md](./CONTEXT.md). Use the canonical terms; don't drift to synonyms the glossary marks `_Avoid_:`.
- **Architectural decisions**: [docs/adr/](./docs/adr/). Flag conflicts before contradicting an ADR.
- **Roadmap and milestone acceptance criteria**: [docs/roadmap.md](./docs/roadmap.md).

## Agent skills

### Issue tracker

GitHub Issues via `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical labels with default vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` + one `docs/adr/` at repo root. See `docs/agents/domain.md`.
