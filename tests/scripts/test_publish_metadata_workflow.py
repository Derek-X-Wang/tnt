"""Structural assertions on `.github/workflows/publish-metadata.yml`.

Closes issue #10: the appcast publish must run first, the tap-bump job
must run only after appcast succeeded, and a failure-path step must
file a tracking issue on the tnt repo so the maintainer notices.

Stdlib + PyYAML. Skips cleanly if PyYAML is unavailable (the workflow
itself doesn't depend on these tests for CI to pass — these are local
regression guards for the role file's check chain).
"""

from __future__ import annotations

import unittest
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover — local convenience
    yaml = None  # type: ignore[assignment]


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "publish-metadata.yml"


@unittest.skipIf(yaml is None, "PyYAML not installed; skipping workflow structure test")
class PublishMetadataWorkflowTests(unittest.TestCase):
    """Pin the tap-bump job's contract so a future edit can't silently break it."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.doc = yaml.safe_load(WORKFLOW.read_text())  # type: ignore[union-attr]

    def test_appcast_job_present(self) -> None:
        # publish-metadata is the appcast job; tap-bump depends on it
        # so the appcast lands on gh-pages before the tap PR opens.
        self.assertIn("publish-metadata", self.doc["jobs"])

    def test_tap_bump_job_present_and_serialized_after_appcast(self) -> None:
        jobs = self.doc["jobs"]
        self.assertIn(
            "tap-bump",
            jobs,
            "tap-bump job missing — issue #10 requires the publish-metadata "
            "workflow to bump the Homebrew tap after appcast succeeds.",
        )
        needs = jobs["tap-bump"].get("needs")
        # Tap failure must not block the appcast — `needs: publish-metadata`
        # serializes them so appcast lands first.
        self.assertEqual(needs, "publish-metadata")

    def test_tap_bump_invokes_render_script(self) -> None:
        steps = self.doc["jobs"]["tap-bump"]["steps"]
        self.assertTrue(
            any(
                "scripts/render-homebrew.py" in (step.get("run") or "")
                for step in steps
            ),
            "tap-bump job must invoke scripts/render-homebrew.py to "
            "generate Casks/tnt.rb.",
        )

    def test_tap_bump_uses_homebrew_tap_pat_secret(self) -> None:
        steps = self.doc["jobs"]["tap-bump"]["steps"]
        # The PAT is required to push to Derek-X-Wang/homebrew-tnt and
        # to open the PR against that repo (default GITHUB_TOKEN can't
        # cross-repo write).
        env_references_secret = any(
            "HOMEBREW_TAP_PAT" in str(step.get("env") or "")
            for step in steps
        )
        self.assertTrue(
            env_references_secret,
            "tap-bump must read secrets.HOMEBREW_TAP_PAT via env.",
        )

    def test_tap_bump_clones_homebrew_tnt_repo(self) -> None:
        steps = self.doc["jobs"]["tap-bump"]["steps"]
        self.assertTrue(
            any(
                "homebrew-tnt" in (step.get("run") or "")
                for step in steps
            ),
            "tap-bump must clone Derek-X-Wang/homebrew-tnt.",
        )

    def test_tap_bump_opens_pr_on_tap_repo(self) -> None:
        steps = self.doc["jobs"]["tap-bump"]["steps"]
        self.assertTrue(
            any(
                "gh pr create" in (step.get("run") or "")
                and "homebrew-tnt" in (step.get("run") or "")
                for step in steps
            ),
            "tap-bump must run `gh pr create --repo Derek-X-Wang/homebrew-tnt`.",
        )

    def test_tap_bump_uses_bump_tag_branch_naming(self) -> None:
        steps = self.doc["jobs"]["tap-bump"]["steps"]
        self.assertTrue(
            any("bump-" in (step.get("run") or "") for step in steps),
            "tap-bump must push to a `bump-<tag>` branch on the tap repo.",
        )

    def test_tap_bump_has_continue_on_error_protection(self) -> None:
        # The bump step itself uses continue-on-error: true so a tap
        # repo outage doesn't fail the overall workflow after appcast
        # already shipped.
        steps = self.doc["jobs"]["tap-bump"]["steps"]
        self.assertTrue(
            any(step.get("continue-on-error") is True for step in steps),
            "tap-bump's main step must set continue-on-error: true so "
            "a tap-side failure can be reported instead of breaking the "
            "release pipeline.",
        )

    def test_tap_bump_has_failure_tracking_issue_step(self) -> None:
        steps = self.doc["jobs"]["tap-bump"]["steps"]
        # The failure path step must file an issue on the main tnt repo
        # using github.token (the PAT is fine-scoped to homebrew-tnt and
        # cannot create issues on Derek-X-Wang/tnt).
        self.assertTrue(
            any(
                "gh issue create" in (step.get("run") or "")
                and "github.token" in str(step.get("env") or "")
                for step in steps
            ),
            "tap-bump must include a follow-up step that opens a "
            "tracking issue on Derek-X-Wang/tnt when the bump step "
            "fails (gated by steps.<bump>.outcome != 'success').",
        )


if __name__ == "__main__":
    unittest.main()
