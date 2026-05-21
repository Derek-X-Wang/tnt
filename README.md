# TNT

Voice-first **Personal Master Agent** for macOS. Sits between a single human user and many AI **Worker Agents** (Claude Code, Cursor, OpenCode, custom) and reduces the reading + cognitive load of running them in parallel.

## Status

v0 in active development. See [`docs/roadmap.md`](./docs/roadmap.md) for milestones and acceptance demos.

## Install

Once the first signed alpha ships, the recommended path is Homebrew:

```sh
brew tap Derek-X-Wang/tnt
brew install --cask tnt
```

Or download the signed `.dmg` from the [latest GitHub Release](https://github.com/Derek-X-Wang/tnt/releases) and drag `TNT.app` into Applications.

TNT auto-updates in place via [Sparkle](https://sparkle-project.org): the menu-bar menu's **Check for Updates…** item triggers an immediate check, and a background check fires once per day. The update feed lives at `https://derek-x-wang.github.io/tnt/appcast.xml`; release archives are EdDSA-signed and verified before being applied. See [`docs/release.md`](./docs/release.md) for the release operator's runbook.

## Domain language

Read [`CONTEXT.md`](./CONTEXT.md) before contributing — it defines the canonical vocabulary (Personal Master Agent, Worker Agent, Voice Turn, Capture Set, Capture Chip, Session Event, Cognitive Engine, Memory Store, Future Server Boundary). Don't drift to synonyms the glossary marks `_Avoid_:`.

Architectural decisions live in [`docs/adr/`](./docs/adr/).

## Open the workspace

```sh
open apps/swift/TNT.xcworkspace
```

Requires Xcode 16+ on macOS 14+. The workspace contains three targets — `TNTMac` (the menu-bar Desktop App), `TNTiOS` (iOS stub for v0), `TNTCLI` (the bundled `tnt` command-line tool that Worker Agents call to push **Session Events** into the **Local Ingest** endpoint) — and six Swift Packages under `apps/swift/Packages/`.

## Build from the command line

```sh
xcodebuild -workspace apps/swift/TNT.xcworkspace \
  -scheme TNTMac -configuration Debug build
```

Each Swift Package also builds standalone:

```sh
swift build --package-path apps/swift/Packages/TNTCore
```

## License

Apache-2.0. See [`LICENSE`](./LICENSE) and [`NOTICE`](./NOTICE).
