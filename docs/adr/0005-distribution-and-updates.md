# Distribution and auto-update

TNT v0 ships as a signed + notarized macOS `.dmg` via GitHub Releases, with Sparkle handling auto-updates against an `appcast.xml` published from the same release pipeline. A Homebrew Cask is generated each release. The signing/notarization/appcast/cask scripts and GitHub Actions workflow are mirrored from `ContextFS/ctxfs`, which already runs this pipeline successfully.

## Why

The product needs Microphone, Accessibility, and Screen Recording permissions on first launch. macOS Gatekeeper treats unsigned apps requesting those permissions as suspicious; an unsigned `.dmg` would create a hostile first-run UX (right-click-Open, repeated TCC warnings, "is this malware?" doubt) that contradicts the magical-feel goal. Auto-update via Sparkle is mandatory because v0 will iterate weekly and we cannot expect users to download new dmgs manually.

The Apple Developer ID and the entire signing/notarization/appcast/cask pipeline already exist in a sibling project; copying them is hours of work, not days. The cost-of-doing-this-right is therefore near zero.

## What we copy from ctxfs

- `scripts/release.sh` — orchestrates build → sign → notarize → staple → dmg → appcast append → cask render
- `scripts/append-appcast-item.py` — Sparkle appcast generator
- `scripts/render-homebrew.py` — Homebrew Cask formula generator
- `.github/workflows/release.yml` — runs the above on tag push
- `Packages/Sparkle` integration pattern (and `SparkleMenuAction.swift`)
- `OnboardingView.swift` shape — TNT adapts it for the privacy consent screen
- `MenuBarView.swift` + `MenuContent.swift` shape — direct fit for TNT's menu-bar presence
- `LoginItem.swift` — for "start TNT at login"
- `*.entitlements` — adapted for TNT's TCC needs (mic, AX, screen capture, network client)

## Consequences

- Apple Developer ID credentials must be in GitHub Actions secrets. OSS forks cannot release signed builds; that's expected — they can build from source and sign with their own ID.
- Sparkle's appcast must be served from a stable HTTPS endpoint. v0 uses GitHub Pages off the repo (same as ctxfs).
- v0 release cadence: every notable change is a tag → a release. No "preview" track v0; if needed, add later via Sparkle channels.
