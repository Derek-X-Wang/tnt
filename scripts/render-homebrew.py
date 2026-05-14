#!/usr/bin/env python3
"""Render Casks/tnt.rb (and a placeholder Formula/tnt.rb) from release metadata.

Called by the publish-metadata workflow with version + SHA-256s and the
source repo slug. Writes two Ruby files that Homebrew parses.

TNT ships a signed `.dmg` only (the bundled `tnt` CLI lives inside the
.app and is not distributed as a separate tarball v0). The formula is
written but kept minimal because there are no standalone CLI tarballs
yet; revisit when `tnt` is shipped outside the .app.

Stdlib only — no PyPI deps.
"""

import argparse
import os
import sys
import textwrap


CASK_TEMPLATE = textwrap.dedent("""\
    cask "tnt" do
      version "{version}"
      sha256 "{dmg_sha}"

      url "https://github.com/{repo_slug}/releases/download/{tag}/TNT-#{{version}}.dmg"
      name "TNT"
      desc "Voice-first personal master agent for the AI-agent era"
      homepage "https://github.com/{repo_slug}"

      app "TNT.app"
      binary "#{{appdir}}/TNT.app/Contents/MacOS/tnt"

      zap trash: [
        "~/.tnt",
        "~/Library/Preferences/com.derekxwang.tnt.companion.plist",
        "~/Library/Application Support/com.derekxwang.tnt.companion",
        "~/Library/Caches/com.derekxwang.tnt.companion",
      ]
    end
""")


FORMULA_TEMPLATE = textwrap.dedent("""\
    # Placeholder formula. TNT v0 ships only the macOS .app via the cask
    # above; the bundled `tnt` CLI is reachable as a binary inside the
    # cask install. When TNT starts shipping a standalone CLI tarball
    # (post-v0, see roadmap), this formula will pull that artifact and
    # the cask's `binary "#{{appdir}}/..."` line will be dropped.
    class Tnt < Formula
      desc "Voice-first personal master agent for the AI-agent era"
      homepage "https://github.com/{repo_slug}"
      version "{version}"
      license "Apache-2.0"

      conflicts_with cask: "tnt"

      def install
        odie "tnt does not yet ship a standalone CLI tarball; install via `brew install --cask tnt` instead"
      end

      test do
        system "true"
      end
    end
""")


def render_cask(*, version: str, tag: str, repo_slug: str, dmg_sha: str) -> str:
    return CASK_TEMPLATE.format(
        version=version,
        tag=tag,
        repo_slug=repo_slug,
        dmg_sha=dmg_sha,
    )


def render_formula(*, version: str, tag: str, repo_slug: str) -> str:
    return FORMULA_TEMPLATE.format(
        version=version,
        tag=tag,
        repo_slug=repo_slug,
    )


def _validate_sha(name: str, value: str) -> None:
    if len(value) != 64 or not all(c in "0123456789abcdef" for c in value.lower()):
        raise ValueError(f"--{name} must be a 64-char hex SHA-256, got {value!r}")


def main() -> int:
    p = argparse.ArgumentParser(description="Render Homebrew cask + formula for TNT")
    p.add_argument("--version", required=True)
    p.add_argument("--tag", required=True)
    p.add_argument("--repo-slug", required=True, help="e.g. Derek-X-Wang/tnt")
    p.add_argument("--dmg-sha", required=True)
    p.add_argument("--cask-out", required=True, help="path to write Casks/tnt.rb")
    p.add_argument(
        "--formula-out",
        required=False,
        help="path to write Formula/tnt.rb (placeholder until standalone CLI ships)",
    )
    args = p.parse_args()

    _validate_sha("dmg-sha", args.dmg_sha)

    if not args.tag.startswith("v"):
        print(f"error: --tag must start with 'v', got {args.tag!r}", file=sys.stderr)
        return 2

    if args.tag[1:] != args.version:
        print(
            f"error: --tag ({args.tag!r}) and --version ({args.version!r}) must agree",
            file=sys.stderr,
        )
        return 2

    cask = render_cask(
        version=args.version,
        tag=args.tag,
        repo_slug=args.repo_slug,
        dmg_sha=args.dmg_sha,
    )

    os.makedirs(os.path.dirname(args.cask_out) or ".", exist_ok=True)
    with open(args.cask_out, "w") as f:
        f.write(cask)
    print(f"wrote {args.cask_out}")

    if args.formula_out:
        formula = render_formula(
            version=args.version,
            tag=args.tag,
            repo_slug=args.repo_slug,
        )
        os.makedirs(os.path.dirname(args.formula_out) or ".", exist_ok=True)
        with open(args.formula_out, "w") as f:
            f.write(formula)
        print(f"wrote {args.formula_out}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
