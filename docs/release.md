# Cutting a TNT release

This is the operational runbook for the maintainer. The pipeline mirrors the working `ContextFS/ctxfs` setup; deviations are noted inline.

## One-time setup (HITL — issue #4)

These steps run **once per repo** (not per release). They cannot be automated because they require credentials that only the maintainer holds.

### 1. Apple Developer ID Application certificate

Already issued to **Xinzhe Wang (RDQSC33B2X)**. The release pipeline uses the identity string `Developer ID Application: Xinzhe Wang (RDQSC33B2X)` (set as `DEVELOPER_ID_IDENTITY` env in `.github/workflows/release.yml`).

If a fresh `.p12` export is needed:

1. **Keychain Access → My Certificates** → right-click "Developer ID Application: Xinzhe Wang" → **Export**.
2. Save as `developer-id.p12` with a strong password.
3. `base64 -i developer-id.p12 -o developer-id.p12.base64` (macOS), then copy that one-line file.

Add the two GitHub Actions secrets:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | the contents of `developer-id.p12.base64` |
| `DEVELOPER_ID_P12_PASSWORD` | the password used during export |

### 2. Apple notarization credentials

The release workflow notarizes via `xcrun notarytool` using an **app-specific password**, not the maintainer's real Apple-ID password.

1. <https://appleid.apple.com> → Sign In and security → **App-Specific Passwords** → Generate a new one labeled e.g. `tnt-notarytool-ci`.
2. Copy the password (Apple shows it once).

Add three GitHub Actions secrets:

| Secret | Value |
| --- | --- |
| `APPLE_ID` | the maintainer's Apple-ID email |
| `APPLE_ID_PASSWORD` | the app-specific password from step 1 |
| `APPLE_TEAM_ID` | `RDQSC33B2X` |

### 3. Sparkle EdDSA key pair

Sparkle 2.x signs each update archive with an **EdDSA** (Ed25519) key. The public key is embedded in the shipped app's `Info.plist` (as `SUPublicEDKey`); the matching private key signs the `.zip` in CI. Generate once and never rotate without a forced full-update event.

```sh
# Pull the Sparkle CLI tools to a scratch dir (only needed locally).
SPARKLE_VERSION=2.9.1
curl -fL -o /tmp/Sparkle.tar.xz \
  "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
tar -xJf /tmp/Sparkle.tar.xz -C /tmp/sparkle-tools

# Generate the key pair. Stores the private key in your login keychain.
/tmp/sparkle-tools/bin/generate_keys

# Extract the public key (prints to stdout).
/tmp/sparkle-tools/bin/generate_keys -p
# → "WUlpGGW6BOEK5wrpaXmx/PsS5l/ldtxOrGzS/w2QYKQ=" (example)

# Extract the private key (prints to stdout — **secret**!).
/tmp/sparkle-tools/bin/generate_keys -x /tmp/sparkle_ed_priv
cat /tmp/sparkle_ed_priv
```

Then:

1. Open `apps/swift/project.yml` and set `INFOPLIST_KEY_SUPublicEDKey` to the **public** key string. Run `(cd apps/swift && xcodegen generate)` and commit.
2. Add the **private** key as the `SPARKLE_PRIVATE_KEY` GitHub Actions secret. **Do not** commit it anywhere.
3. Securely back up `/tmp/sparkle_ed_priv` (1Password, a hardware token, etc.) and shred the file. Losing this key forces every installed copy of TNT to re-install manually — Sparkle treats a key change as untrusted.

### 4. `gh-pages` branch for the appcast

Sparkle reads `SUFeedURL = https://derek-x-wang.github.io/tnt/appcast.xml`. The `publish-metadata.yml` workflow writes to the `gh-pages` branch; that branch must exist:

```sh
git checkout --orphan gh-pages
git rm -rf .
echo "TNT update feed" > README.md
git add README.md
git commit -m "init: gh-pages for Sparkle appcast"
git push origin gh-pages
git checkout main
```

In repo Settings → Pages, set source to `gh-pages` / `/ (root)`. The first time `publish-metadata.yml` runs, it seeds `appcast.xml` if missing.

### 5. (Optional, not v0) Homebrew tap repo

`scripts/render-homebrew.py` produces a Cask formula referencing the signed `.dmg`, but TNT v0 does **not** wire the tap-bump step in CI — that work lives in issue #10. When ready, create `Derek-X-Wang/homebrew-tnt`, mirror `ctxfs`'s `Casks/` + `Formula/` layout, and add a `HOMEBREW_TAP_PAT` secret to publish-metadata.yml.

## Cutting a release

### 1. Write the release notes

```sh
# pick the next version
VERSION=0.0.2
mkdir -p .github/release-notes
$EDITOR .github/release-notes/v${VERSION}.md
git add .github/release-notes/v${VERSION}.md
git commit -m "docs: release notes for v${VERSION}"
```

The release workflow refuses to build if this file is missing or empty. The `publish-metadata.yml` step renders this Markdown into the Sparkle update dialog's `<description>` HTML.

### 2. Stamp the version locally

```sh
scripts/release.sh 0.0.2
```

What it does:

- Asserts the working tree is clean (untracked files OK; tracked-file modifications NO).
- Asserts `.github/release-notes/v0.0.2.md` exists and is non-empty.
- Asserts the tag does not yet exist locally.
- Writes `0.0.2` into the `VERSION` file.
- Stamps `MARKETING_VERSION = 0.0.2;` and `CURRENT_PROJECT_VERSION = <next build number>;` in every config in `apps/swift/TNT.xcodeproj/project.pbxproj`.
- Commits + tags `v0.0.2` locally. **Does not push.**

The build number is derived from `git rev-list --count HEAD + 1` so each release commit's build number is monotonically `n+1` where `n` is the previous count. This matters because Sparkle's `SUStandardVersionComparator` compares `<sparkle:version>` against `CFBundleVersion` — passing the semver string against a build number misorders updates (the `v0.1.1` incident in ctxfs).

### 3. Inspect + push

```sh
git log -1
git show -1 --stat
git push origin main
git push origin v0.0.2
```

The tag push fires `release.yml`. Watch <https://github.com/Derek-X-Wang/tnt/actions>.

### 4. After the draft Release is created

The workflow attaches the signed `.dmg`, the signed Sparkle `.zip`, the `.zip.sig`, and `checksums.txt`. Open the draft, sanity-check the version + asset list, edit the body if needed, and click **Publish release**.

Publishing fires `publish-metadata.yml`, which:

- Downloads the `.zip` + `.sig` + `checksums.txt`.
- Reads `CFBundleVersion` from inside the `.zip` (Sparkle build-number gotcha above).
- Renders the release-notes Markdown → HTML.
- Appends a new `<item>` to `appcast.xml` on `gh-pages`.
- Pushes the updated appcast.

Installed copies of TNT see the new version within `SUScheduledCheckInterval` (default 86400 seconds — once per day) or whenever the user picks **Check for Updates…**.

### 5. Smoke-test the installed update

On a separate Mac (or after deleting `~/Library/Preferences/com.derekxwang.tnt.companion.plist` locally):

1. Install the **previous** signed `.dmg` and launch it.
2. Click **Check for Updates…** in TNT's menu-bar menu.
3. Confirm Sparkle prompts for the new version, downloads, verifies the EdDSA signature, and relaunches into the new build.

If Sparkle rejects the signature, check that:

- `SUPublicEDKey` in the installed copy's `Info.plist` matches the public key generated above.
- `SPARKLE_PRIVATE_KEY` in GitHub Actions matches the corresponding private key.
- The `.zip.sig` on the Release matches what `sign_update --verify` accepts locally.

## Rotating secrets

If any of the five GitHub Actions secrets need to rotate, repeat the relevant step in **One-time setup** and replace the value in repo Settings → Secrets and variables → Actions. The pipeline picks up the new value on the next tag push.

**Never** rotate `SPARKLE_PRIVATE_KEY` casually — every existing install verifies updates against the matching public key. A key rotation forces a manual reinstall for every user.

## Troubleshooting

- `release.yml` step "Import Developer ID cert" errors `keychain "build.keychain": item not found` → the `.p12` base64 secret is malformed or its password is wrong. Re-export and re-encode.
- Notarization log shows `The signature of the binary is invalid` for `Sparkle.framework/.../XPCServices/Downloader.xpc` → the nested-resign loop missed a bundle. Add the bundle path to the `for xpc in Downloader Installer` block in `release.yml` and re-tag.
- `publish-metadata.yml` step "Extract CFBundleVersion" fails with `outer TNT.app Info.plist not found in release zip` → the `.zip` is malformed or the bundle id changed. Confirm `apps/swift/project.yml`'s `PRODUCT_BUNDLE_IDENTIFIER` matches the path filter in the Python snippet (`TNT.app/Contents/Info.plist`).
- Sparkle dialog says "TNT is up to date" but a newer version exists in the appcast → `<sparkle:version>` was likely set to the marketing string instead of `CFBundleVersion`. Inspect `gh-pages/appcast.xml` for the new `<item>`; the value should be the integer build number, not `0.0.2`.
