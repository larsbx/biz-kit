"""Negative and positive tests for advisory, fail-closed CI impact planning."""
from __future__ import annotations

import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
import sys
SPEC = importlib.util.spec_from_file_location("ci_impact_selector",
                                             ROOT / "tools" / "ci_impact_selector.py")
assert SPEC and SPEC.loader
module = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = module
SPEC.loader.exec_module(module)

HEAD = "a" * 40
BASE = "b" * 40


class ImpactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "tools").mkdir()
        (self.root / "apps").mkdir()
        (self.root / ".github" / "workflows").mkdir(parents=True)
        for app, deps in (
            ("inventory_core", []),
            ("commerce_core", []),
            ("biz_kit_composition", ["inventory_core", "commerce_core"]),
            ("dispatch", []),
        ):
            folder = self.root / "apps" / app
            folder.mkdir()
            dep_text = ", ".join("{:" + dep + ", in_umbrella: true}" for dep in deps)
            (folder / "mix.exs").write_text(
                f"def project, do: [app: :{app}, deps: [{dep_text}]]\n",
                encoding="utf-8")
        self.policy = {
            "schema": "biz-kit-impact-policy-v1",
            "authority": "advisory-no-skip-no-required-check",
            "safe_app_roots": ["commerce_core", "inventory_core", "biz_kit_composition"],
            "always_pr_workflows": ["consolidation.yml", "portal-auth-acceptance.yml"],
            "workflow_owners": {
                "inventory-core.yml": ["inventory_core"],
                "commerce-core.yml": ["commerce_core"],
                "business-composition.yml": ["biz_kit_composition"],
            },
        }
        self.save_policy()

    def save_policy(self):
        (self.root / module.POLICY).write_text(
            json.dumps(self.policy), encoding="utf-8")
        for filename in (set(self.policy["workflow_owners"]) |
                         set(self.policy["always_pr_workflows"])):
            (self.root / ".github" / "workflows" / filename).write_text(
                "name: test\n", encoding="utf-8")

    def compute(self, paths):
        return module.plan(self.root, module.read_policy(self.root), HEAD,
                           "pull_request", paths=paths)

    def test_source_derived_transitive_consumer_is_included(self):
        result = self.compute(["apps/inventory_core/lib/inventory.ex"])
        self.assertEqual(result["mode"], "focused_advisory")
        self.assertEqual(result["direct_apps"], ["inventory_core"])
        self.assertEqual(result["dependent_apps"],
                         ["biz_kit_composition", "inventory_core"])
        self.assertEqual(result["proposed_focused_workflows"],
                         ["business-composition.yml", "inventory-core.yml"])
        self.assertEqual(result["always_pr_workflows"],
                         ["consolidation.yml", "portal-auth-acceptance.yml"])

    def test_unknown_path_requires_full_fallback(self):
        for path in ("apps/dispatch/lib/dispatch.ex",
                     "apps/other/lib/other.ex",
                     "scripts/verify.sh", ".github/workflows/ci.yml",
                     "docs/contracts/schema.json", "mix.lock",
                     "apps/inventory_core/mix.exs"):
            with self.subTest(path=path):
                output = self.compute([path])
                self.assertEqual(output["mode"], "full_fallback")
                self.assertEqual(len(output["proposed_focused_workflows"]), 3)

    def test_mixed_sensitive_and_pure_files_are_full(self):
        output = self.compute(["apps/inventory_core/test/inventory_test.exs",
                               "apps/dispatch/test/driver_test.exs"])
        self.assertEqual(output["mode"], "full_fallback")

    def test_sensitive_transitive_consumer_falls_back_full(self):
        # A pure producer is not safe to scope if a sensitive host depends on it.
        (self.root / "apps" / "dispatch" / "mix.exs").write_text(
            "def project, do: [app: :dispatch, "
            "deps: [{:inventory_core, in_umbrella: true}]]\n",
            encoding="utf-8")
        output = self.compute(["apps/inventory_core/lib/inventory.ex"])
        self.assertEqual(output["mode"], "full_fallback")
        self.assertTrue(any("incomplete-dependency-evidence" in r
                            for r in output["reason_codes"]))

    def test_empty_diff_is_full_and_not_silent_skip(self):
        output = self.compute([])
        self.assertEqual(output["mode"], "full_fallback")
        self.assertIn("empty-diff-full-fallback", output["reason_codes"])

    def test_all_non_pr_events_require_full(self):
        for event in ("push", "merge_group", "schedule", "workflow_dispatch"):
            with self.subTest(event=event):
                output = module.plan(self.root, module.read_policy(self.root),
                                     HEAD, event, force_full=True)
                self.assertEqual(output["mode"], "full_fallback")
                self.assertIn(f"unconditional-{event}", output["reason_codes"])

    def test_non_pr_cannot_propose_focused(self):
        with self.assertRaises(module.EvidenceError):
            module.plan(self.root, module.read_policy(self.root), HEAD,
                        "merge_group", paths=["apps/inventory_core/lib/a.ex"])

    def test_missing_dependency_source_falls_back_full(self):
        manifest = self.root / "apps/biz_kit_composition/mix.exs"
        manifest.write_text(
            "def project, do: [app: :biz_kit_composition, "
            "deps: [{:inventory_core, only: :test, in_umbrella: true}]]\n",
            encoding="utf-8")
        output = self.compute(["apps/inventory_core/lib/i.ex"])
        self.assertEqual(output["mode"], "full_fallback")
        self.assertTrue(any("incomplete-dependency-evidence" in r
                            for r in output["reason_codes"]))

    def test_policy_missing_a_declared_workflow_fails(self):
        (self.root / ".github" / "workflows" / "inventory-core.yml").unlink()
        with self.assertRaises(module.EvidenceError):
            module.read_policy(self.root)

    def test_invalid_paths_are_rejected_not_silently_ignored(self):
        for path in ("/tmp/data", "../escape", "apps//test.ex", "apps\\evil"):
            with self.subTest(path=path):
                with self.assertRaises(module.EvidenceError):
                    self.compute([path])

    def test_both_sides_of_renames_are_counted(self):
        frames = (b"R100\x00apps/inventory_core/lib/old.ex\x00"
                  b"apps/dispatch/lib/new.ex\x00M\x00mix.lock\x00")
        with patch.object(module.subprocess, "check_output",
                          side_effect=[(HEAD + "\n").encode(), frames]):
            self.assertEqual(module.changed_paths(self.root, BASE, HEAD), [
                "apps/dispatch/lib/new.ex",
                "apps/inventory_core/lib/old.ex",
                "mix.lock",
            ])

    def test_unsupported_diff_status_blocks(self):
        with patch.object(module.subprocess, "check_output",
                          side_effect=[(HEAD + "\n").encode(), b"Z\x00x\x00"]):
            with self.assertRaises(module.EvidenceError):
                module.changed_paths(self.root, BASE, HEAD)

    def test_wrong_checkout_revision_blocks(self):
        with patch.object(module.subprocess, "check_output",
                          return_value=(BASE + "\n").encode()):
            with self.assertRaises(module.EvidenceError):
                module.changed_paths(self.root, BASE, HEAD)

    def test_git_diff_failure_blocks(self):
        with patch.object(module.subprocess, "check_output",
                          side_effect=[(HEAD + "\n").encode(),
                                       subprocess.CalledProcessError(128, "git")]):
            with self.assertRaises(module.EvidenceError):
                module.changed_paths(self.root, BASE, HEAD)

    def test_current_umbrella_reverse_edges_and_sensitive_fallback(self):
        # Exercise the real repository rather than relying only on toy fixtures.
        graph = module.umbrella_graph(ROOT)
        self.assertGreaterEqual(len(graph), 32)
        self.assertIn("biz_kit_composition", module.dependents(graph, {"sales_core"}))
        policy = module.read_policy(ROOT)
        sales = module.plan(ROOT, policy, HEAD, "pull_request",
                            paths=["apps/sales_core/lib/sales_core.ex"])
        self.assertEqual(sales["mode"], "focused_advisory")
        self.assertIn("biz_kit_composition", sales["dependent_apps"])
        inventory = module.plan(ROOT, policy, HEAD, "pull_request",
                                paths=["apps/inventory_core/lib/inventory_core.ex"])
        self.assertEqual(inventory["mode"], "full_fallback")

    def test_policy_and_graph_receipts_are_stable(self):
        first = self.compute(["apps/inventory_core/test/one_test.exs"])
        second = self.compute(["apps/inventory_core/test/one_test.exs"])
        self.assertEqual(module.digest(first), module.digest(second))
        self.assertEqual(len(first["umbrella_graph_sha256"]), 64)
        self.assertEqual(len(first["policy_sha256"]), 64)


if __name__ == "__main__":
    unittest.main()
