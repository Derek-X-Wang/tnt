# Desktop-only v0, no remote server

v0 ships as a single macOS app — no `tnt-server` process, no hosted backend. Memory is local SQLite, secrets are BYOK in `~/.tnt/config`, the Realtime WS connects directly from the Desktop App to OpenAI, and Worker Agents push Session Events into a localhost-only ingest endpoint via the bundled `tnt` CLI. Multi-device, hosted offerings, and a remote brain are explicit non-goals for v0.

## Why

The spec emphasizes "lightweight," "personally usable every day," and "do not overbuild." A server adds hosting, auth, deployment, and OSS self-host friction without buying anything v0 needs. Multi-device coordination is in the long-term vision but not the MVP. Choosing local-only buys: zero deploy story, OSS users `git clone && open Xcode`, no auth model to design, and no key-handling-on-server liability.

## Considered alternatives

- **Desktop + thin localhost server process** — splits memory/UI cleanly but doubles processes for no v0 benefit.
- **Desktop + remote server (hosted or self-host)** — enables multi-device but contradicts "lightweight" and forces auth/deployment work that delays the first magical demo by weeks.

## Consequences

- The Realtime API key lives on the user's machine. No proxy, so `tnt` cannot enforce rate-limits or share a hosted key.
- Multi-device sync requires a server later — v0 design must keep a server-shaped seam (the Memory Store interface) so a remote impl can replace local SQLite without touching call sites.
- Worker Agent integration is push-only over loopback HTTP for now; bidirectional control (TNT → agent) is post-v0.
