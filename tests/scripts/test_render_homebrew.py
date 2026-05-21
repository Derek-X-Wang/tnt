"""Regression tests for `scripts/render-homebrew.py`.

These guard the Cask + Formula shape that the tap-bump job in
`.github/workflows/publish-metadata.yml` relies on. Drift in
`render-homebrew.py` would silently ship a broken `Casks/tnt.rb` on the
next release tag; the test failure surfaces it pre-merge.

Stdlib only — runs as `python3 -m unittest discover tests/scripts`
without any extra deps.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "render-homebrew.py"


def _run(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True,
        text=True,
        check=False,
    )


class RenderHomebrewTests(unittest.TestCase):
    """Lock the Cask + Formula shape the tap-bump workflow consumes."""

    def test_help_exits_zero(self) -> None:
        # `python3 scripts/render-homebrew.py --help` is the smoke test
        # listed in docs/agents/afk-runner.md. Keep it green.
        r = _run(["--help"])
        self.assertEqual(r.returncode, 0, msg=r.stderr)
        self.assertIn("--cask-out", r.stdout)
        self.assertIn("--formula-out", r.stdout)

    def test_renders_cask_with_expected_fields(self) -> None:
        sha = "a" * 64
        with tempfile.TemporaryDirectory() as tmp:
            cask = Path(tmp) / "Casks" / "tnt.rb"
            r = _run(
                [
                    "--version",
                    "0.0.1",
                    "--tag",
                    "v0.0.1",
                    "--repo-slug",
                    "Derek-X-Wang/tnt",
                    "--dmg-sha",
                    sha,
                    "--cask-out",
                    str(cask),
                ]
            )
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            text = cask.read_text()
            self.assertIn('cask "tnt" do', text)
            self.assertIn('version "0.0.1"', text)
            self.assertIn(f'sha256 "{sha}"', text)
            # URL must reference the tag and the runtime-interpolated
            # version literal — render-homebrew.py escapes the inner
            # `#{version}` so Homebrew expands it, not Python.
            self.assertIn(
                "https://github.com/Derek-X-Wang/tnt/releases/download/v0.0.1/TNT-#{version}.dmg",
                text,
            )
            self.assertIn('app "TNT.app"', text)
            # Bundled `tnt` CLI inside the .app shows up via cask's binary stanza.
            self.assertIn('binary "#{appdir}/TNT.app/Contents/MacOS/tnt"', text)
            # Zap stanza removes BYOK config + Sparkle prefs on uninstall.
            self.assertIn('"~/.tnt"', text)
            self.assertIn(
                '"~/Library/Preferences/com.derekxwang.tnt.companion.plist"',
                text,
            )

    def test_renders_formula_when_requested(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cask = Path(tmp) / "Casks" / "tnt.rb"
            formula = Path(tmp) / "Formula" / "tnt.rb"
            r = _run(
                [
                    "--version",
                    "0.0.1",
                    "--tag",
                    "v0.0.1",
                    "--repo-slug",
                    "Derek-X-Wang/tnt",
                    "--dmg-sha",
                    "b" * 64,
                    "--cask-out",
                    str(cask),
                    "--formula-out",
                    str(formula),
                ]
            )
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            text = formula.read_text()
            self.assertIn("class Tnt < Formula", text)
            # Placeholder until standalone CLI tarball ships post-v0.
            self.assertIn('conflicts_with cask: "tnt"', text)
            self.assertIn("odie", text)

    def test_tag_must_start_with_v(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cask = Path(tmp) / "Casks" / "tnt.rb"
            r = _run(
                [
                    "--version",
                    "0.0.1",
                    "--tag",
                    "0.0.1",
                    "--repo-slug",
                    "Derek-X-Wang/tnt",
                    "--dmg-sha",
                    "c" * 64,
                    "--cask-out",
                    str(cask),
                ]
            )
            self.assertEqual(r.returncode, 2, msg=r.stderr)
            self.assertIn("must start with 'v'", r.stderr)

    def test_tag_version_mismatch_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cask = Path(tmp) / "Casks" / "tnt.rb"
            r = _run(
                [
                    "--version",
                    "0.0.1",
                    "--tag",
                    "v0.0.2",
                    "--repo-slug",
                    "Derek-X-Wang/tnt",
                    "--dmg-sha",
                    "d" * 64,
                    "--cask-out",
                    str(cask),
                ]
            )
            self.assertEqual(r.returncode, 2, msg=r.stderr)
            self.assertIn("must agree", r.stderr)

    def test_short_sha_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cask = Path(tmp) / "Casks" / "tnt.rb"
            r = _run(
                [
                    "--version",
                    "0.0.1",
                    "--tag",
                    "v0.0.1",
                    "--repo-slug",
                    "Derek-X-Wang/tnt",
                    "--dmg-sha",
                    "deadbeef",  # too short
                    "--cask-out",
                    str(cask),
                ]
            )
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("64-char hex SHA-256", r.stderr)


if __name__ == "__main__":
    unittest.main()
