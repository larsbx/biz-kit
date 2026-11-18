"""Regression tests for read-only CI workflow inventory.

This pilot does not authorize changes to the existing required checks.
"""
from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve()
ROOT = HERE.parents[1]
SPEC = importlib.util.spec_from_file_location("ci_workflow_inventory", ROOT / "tools" / "ci_workflow_inventory.py")
assert SPEC and SPEC.loader
import sys
module = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = module
SPEC.loader.exec_module(module)


class InventoryTests(unittest.TestCase):
    def fixture(self, text: str) -> dict:
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "test.yml"
            p.write_text(text, encoding="utf-8")
            return module.inspect_workflow(p)

    def test_scoped_pull_request_with_block_paths(self):
        record = self.fixture('''name: CI
on:
  pull_request:
    paths:
      - 'apps/school_ops/**'
      - '.github/workflows/ci.yml'
  push:
    branches: [main]
jobs:
  unit:
    runs-on: ubuntu-latest
''')
        self.assertEqual(record["status"], "parsed")
        self.assertEqual(record["events"], ["pull_request", "push"])
        self.assertEqual(record["pr_path_patterns"], [
            ".github/workflows/ci.yml", "apps/school_ops/**"
        ])
        self.assertTrue(record["pr_path_filtered"])

    def test_inline_path_list_is_preserved(self):
        record = self.fixture('''on:
  pull_request:
    paths: ["tools/a.py", "docs/a.md"]
jobs:
  test:
    runs-on: ubuntu-latest
''')
        self.assertEqual(record["status"], "parsed")
        self.assertEqual(record["pr_path_patterns"], ["docs/a.md", "tools/a.py"])

    def test_unconditional_pull_request(self):
        record = self.fixture('''on:
  pull_request:
  merge_group:
jobs:
  test:
    runs-on: ubuntu-latest
''')
        self.assertFalse(record["pr_path_filtered"])
        self.assertIn("merge_group", record["events"])

    def test_unknown_inline_event_fails_closed(self):
        record = self.fixture('''on: [pull_request, push]
jobs:
  test:
    runs-on: ubuntu-latest
''')
        self.assertEqual(record["status"], "unknown")

    def test_bad_inline_filter_is_not_assumed_covered(self):
        record = self.fixture('''on:
  pull_request:
    paths: [a/**, b/**]
jobs:
  test:
    runs-on: ubuntu-latest
''')
        self.assertEqual(record["status"], "unknown")

    def test_quoted_pr_trigger_cannot_disappear_after_other_events(self):
        for preceding in ("push", "workflow_dispatch"):
            with self.subTest(preceding=preceding):
                record = self.fixture(f"""on:
  {preceding}:
  "pull_request":
    paths:
      - 'apps/dispatch/**'
jobs:
  test:
    runs-on: ubuntu-latest
""")
                self.assertEqual(record["status"], "unknown")
                self.assertIn("unsupported", record["reason"])

    def test_unsupported_trigger_structure_fails_closed_after_push(self):
        for unusual in ('  "pull_request":', "  *event_anchor:", "  malformed - :"):
            with self.subTest(unusual=unusual):
                record = self.fixture(f"""on:
  push:
{unusual}
jobs:
  test:
    runs-on: ubuntu-latest
""")
                self.assertEqual(record["status"], "unknown")

    def test_common_other_event_lists_and_dispatch_inputs_remain_supported(self):
        record = self.fixture("""on:
  push:
    branches:
      - main
    paths:
      - 'apps/dispatch/**'
  schedule:
    - cron: '17 4 * * *'
  workflow_dispatch:
    inputs:
      d_patch_ref:
        description: Release commit to test
        default: main
jobs:
  test:
    runs-on: ubuntu-latest
""")
        self.assertEqual(record["status"], "parsed")
        self.assertEqual(record["events"], ["push", "schedule", "workflow_dispatch"])

    def test_duplicate_event_fails_closed(self):
        record = self.fixture("""on:
  pull_request:
  push:
  pull_request:
jobs:
  test:
    runs-on: ubuntu-latest
""")
        self.assertEqual(record["status"], "unknown")
        self.assertIn("duplicate trigger event", record["reason"])

    def test_cli_require_complete_exits_nonzero_on_missing_quoted_event(self):
        from unittest.mock import patch
        import contextlib
        import io
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workflows = root / ".github" / "workflows"
            workflows.mkdir(parents=True)
            (workflows / "test.yml").write_text("""on:
  push:
  "pull_request":
    paths: ['apps/dispatch/**']
jobs:
  test:
    runs-on: ubuntu-latest
""", encoding="utf-8")
            with patch.object(sys, "argv", ["inventory", "--root", str(root),
                                            "--require-complete"]):
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(module.main(), 2)

    def test_repo_inventory_is_not_acceptance(self):
        record = module.inventory(ROOT)
        self.assertEqual(record["authority"], "advisory-no-acceptance")
        self.assertEqual(record["coverage"], "complete")
        self.assertGreaterEqual(record["summary"]["total"], 30)
        self.assertTrue(all(w["status"] in ("parsed", "unknown") for w in record["workflows"]))
        self.assertEqual(
            record["summary"]["total"],
            record["summary"]["parsed"] + record["summary"]["unknown"],
        )
        # No exact count snapshot is asserted: workflow coverage can evolve.
        self.assertEqual(len({v["workflow"] for v in record["workflows"]}),
                         record["summary"]["total"])


if __name__ == "__main__":
    unittest.main()
