#!/usr/bin/env bash
# Stamp a new version across VERSION + the Swift Xcode project, create a
# commit + tag. Does NOT push — the maintainer reviews + pushes manually.
#
# Usage:    scripts/release.sh X.Y.Z
# Example:  scripts/release.sh 0.0.1
#
# Precondition:
#   - working tree has no uncommitted changes to tracked files
#   - `.github/release-notes/vX.Y.Z.md` exists and is non-empty
#   - tag `vX.Y.Z` does not yet exist locally
#
# Pattern mirrored from ContextFS/ctxfs/scripts/release.sh. TNT does not
# have a Rust workspace, so the Cargo + lockfile steps from ctxfs are
# intentionally absent here.

set -euo pipefail

# ---- Argument validation ---------------------------------------------------

if [ "$#" -ne 1 ]; then
    echo "usage: $(basename "$0") X.Y.Z" >&2
    exit 64  # EX_USAGE
fi

VERSION="$1"

# Plain semver — no -rc.1 or -beta suffix support for v0.
if ! [[ "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "error: version must be X.Y.Z (plain semver), got: $VERSION" >&2
    exit 64
fi

TAG="v$VERSION"
NOTES_FILE=".github/release-notes/${TAG}.md"

# ---- Cwd: repo root --------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ---- Preconditions ---------------------------------------------------------

# Ignore untracked files — local-tool state (.claude/, .vscode/, .DS_Store)
# is routinely present and shouldn't block a release. `-uno` still reports
# modified or staged tracked files, which we DO want to block on.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "error: working tree has uncommitted changes to tracked files." >&2
    echo "       Commit or stash before releasing." >&2
    git status --short --untracked-files=no >&2
    exit 65  # EX_DATAERR
fi

if [ ! -s "$NOTES_FILE" ]; then
    echo "error: $NOTES_FILE is missing or empty." >&2
    echo "       Write release notes first, commit them, then re-run." >&2
    exit 65
fi

if git rev-parse -q --verify "$TAG" >/dev/null; then
    echo "error: tag $TAG already exists locally." >&2
    exit 65
fi

echo "==> Releasing $TAG"
echo "    Notes file: $NOTES_FILE ($(wc -l <"$NOTES_FILE") lines)"

# ---- Stamp VERSION ---------------------------------------------------------

echo "$VERSION" > VERSION

# ---- Stamp Swift Xcode project --------------------------------------------

PBXPROJ="apps/swift/TNT.xcodeproj/project.pbxproj"

if [ ! -f "$PBXPROJ" ]; then
    echo "error: $PBXPROJ not found." >&2
    echo "       Run \`(cd apps/swift && xcodegen generate)\` first." >&2
    exit 70  # EX_SOFTWARE
fi

# MARKETING_VERSION appears multiple times (one per build configuration /
# target); stamp every occurrence.
sed -i '' -e "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $VERSION;/g" "$PBXPROJ"

# CURRENT_PROJECT_VERSION is a monotonic build number, not the semver.
# Compute this BEFORE the release commit exists, so add 1 — by the time
# the tag points at the release commit, `git rev-list --count HEAD` on
# that commit will equal this number.
BUILD_NUMBER="$(( $(git rev-list --count HEAD) + 1 ))"
sed -i '' -e "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = $BUILD_NUMBER;/g" "$PBXPROJ"

# ---- Stage + commit + tag -------------------------------------------------

# Explicit file list rather than `git add -A`. Keeps untracked .claude/
# state out of the release commit and surfaces any unexpected modification
# as a `git diff` after this script runs.
git add VERSION "$PBXPROJ" "$NOTES_FILE" apps/swift/project.yml 2>/dev/null || true

if git diff --staged --quiet; then
    echo "error: nothing staged after stamping — version may already match." >&2
    exit 70
fi

git commit -m "release: $TAG

Stamps MARKETING_VERSION=$VERSION and CURRENT_PROJECT_VERSION=$BUILD_NUMBER
in $PBXPROJ. Tag $TAG points at this commit and triggers the
.github/workflows/release.yml pipeline to build, sign, notarize, and
upload the .dmg + Sparkle archive to a draft Release."

git tag -a "$TAG" -m "TNT $TAG

Build $BUILD_NUMBER. Release notes: $NOTES_FILE"

echo
echo "==> Committed + tagged $TAG locally."
echo
echo "Next steps:"
echo "  1. Inspect the commit + tag:    git log -1; git tag -v $TAG || git tag -l --format='%(contents)' $TAG"
echo "  2. Push when ready:             git push origin main && git push origin $TAG"
echo "  3. The release.yml workflow fires on the tag push."
