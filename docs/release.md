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

### 5. Homebrew tap PAT

The `tap-bump` job in `publish-metadata.yml` opens a PR on `Derek-X-Wang/homebrew-tnt` bumping `Casks/tnt.rb` to the new release. The default `GITHUB_TOKEN` only writes to the repo the workflow runs in, so a separate fine-scoped Personal Access Token is required.

The tap repo (`Derek-X-Wang/homebrew-tnt`) already exists, public, with `Casks/` + `Formula/` + README scaffolded — there is nothing to create.

**Mint the PAT** (do this once, then rotate when the expiry warning fires):

1. <https://github.com/settings/personal-access-tokens/new> → **Fine-grained tokens** → **Generate new token**.
2. **Token name**: `tnt-tap-bump` (or similar).
3. **Expiration**: 1 year (calendar a reminder; rotation is the only thing that can stop the pipeline silently).
4. **Resource owner**: `Derek-X-Wang`.
5. **Repository access** → **Only select repositories** → pick **`Derek-X-Wang/homebrew-tnt`** (and nothing else — least privilege).
6. **Repository permissions**:
   - **Contents**: Read and write (commit + push the `bump-<tag>` branch).
   - **Pull requests**: Read and write (open the bump PR via `gh pr create`).
   - Leave everything else at "No access."
7. Generate → copy the `github_pat_…` string (shown only once).

Add it as a GitHub Actions secret on the **tnt** repo (not the tap repo):

| Secret | Value |
| --- | --- |
| `HOMEBREW_TAP_PAT` | the `github_pat_…` string from the step above |

The workflow uses this PAT to both push the bump branch and to call `gh pr create --repo Derek-X-Wang/homebrew-tnt`. The follow-up "open tracking issue on tap-bump failure" step uses the default `github.token` because that issue lives back on `Derek-X-Wang/tnt`, which the fine-scoped PAT cannot reach by design.

If this secret is missing or expired, the appcast still publishes (jobs are serialized — appcast first) but the tap-bump step fails loudly and files a tracking issue on this repo so you notice.

### 6. (Out of scope, not v0) standalone CLI tarball

`scripts/render-homebrew.py` also emits a placeholder `Formula/tnt.rb` because the bundled `tnt` CLI ships inside the .app (via the cask's `binary "#{appdir}/TNT.app/Contents/MacOS/tnt"` line) v0. When TNT starts shipping a separate CLI tarball post-v0, the placeholder formula becomes a real one and the cask's `binary` line is removed.

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
