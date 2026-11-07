"""Regression checks for the step dependencies in Biz-kit's Consolidation job."""

import re
import unittest
from pathlib import Path

import yaml


WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/consolidation.yml"
JOB = "ledger-and-orchestration"
COMPILE = "Compile the umbrella"
SPRUCE_DB = "Create and migrate orchestration database"
SPRUCE = "Test orchestration after notes retirement"
EATSBOT_SETUP = "Prepare eatsbot's locale data and database"
EATSBOT = "Test eatsbot (orders, deliveries, storefront API)"
FORMAT = "Verify eatsbot formatting"
REGISTRY = "Test registry revocation across separate database sessions"
NODE = "actions/setup-node@v4"
WEB = "Test the web view's modules"
PLAYWRIGHT = "Install Playwright and Chromium"
BROWSER = "Test the workflow in a browser"
OUTCOME = re.compile(r"steps\.([a-z_]+)\.outcome == 'success'")


class ConsolidationWorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.job = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"][JOB]

    def simulate(self, *failures, cancelled_after=None):
        """Model implicit success() and the explicit guards used by this job."""
        outcomes = {}
        step_ids = {}
        failed = False
        cancelled = False
        for step in self.job["steps"]:
            name = step.get("name") or step["uses"]
            condition = step.get("if")
            if condition is None:
                runs = not (failed or cancelled)
            else:
                prefix = "${{ !cancelled() && "
                self.assertTrue(condition.startswith(prefix) and condition.endswith(" }}"))
                prerequisites = []
                for predicate in condition[len(prefix):-3].split(" && "):
                    match = OUTCOME.fullmatch(predicate)
                    self.assertIsNotNone(match, condition)
                    self.assertIn(match[1], step_ids, condition)
                    prerequisites.append(step_ids[match[1]] == "success")
                runs = not cancelled and all(prerequisites)

            outcome = "skipped"
            if runs:
                outcome = "failure" if name in failures else "success"
                failed |= outcome == "failure"
            outcomes[name] = outcome
            if "id" in step:
                self.assertNotIn(step["id"], step_ids)
                step_ids[step["id"]] = outcome
            cancelled |= name == cancelled_after

        return ("cancelled" if cancelled else "failure" if failed else "success"), outcomes

    def assert_outcomes(self, outcomes, expected, *names):
        for name in names:
            with self.subTest(step=name):
                self.assertEqual(outcomes[name], expected)

    def test_healthy_run_executes_every_suite(self):
        status, outcomes = self.simulate()
        self.assertEqual(status, "success")
        self.assert_outcomes(outcomes, "success", *outcomes)

    def test_spruce_failure_stays_red_and_downstream_suites_execute(self):
        status, outcomes = self.simulate(SPRUCE)
        self.assertEqual(status, "failure")
        self.assert_outcomes(outcomes, "failure", SPRUCE)
        self.assert_outcomes(outcomes, "success", EATSBOT_SETUP, EATSBOT, FORMAT, REGISTRY, WEB, BROWSER)

    def test_earlier_application_failure_still_allows_eatsbot(self):
        status, outcomes = self.simulate("Test Keel normative conformance")
        self.assertEqual(status, "failure")
        self.assert_outcomes(outcomes, "success", EATSBOT_SETUP, EATSBOT, FORMAT, WEB)
        self.assert_outcomes(outcomes, "skipped", SPRUCE_DB, REGISTRY, BROWSER)

    def test_eatsbot_setup_failure_skips_only_its_dependent_suite(self):
        status, outcomes = self.simulate(EATSBOT_SETUP)
        self.assertEqual(status, "failure")
        self.assert_outcomes(outcomes, "skipped", EATSBOT)
        self.assert_outcomes(outcomes, "success", FORMAT, REGISTRY, WEB, BROWSER)

    def test_failing_suites_do_not_block_other_suites(self):
        status, outcomes = self.simulate(EATSBOT, REGISTRY, WEB)
        self.assertEqual(status, "failure")
        self.assert_outcomes(outcomes, "failure", EATSBOT, REGISTRY, WEB)
        self.assert_outcomes(outcomes, "success", FORMAT, PLAYWRIGHT, BROWSER)

    def test_failed_prerequisites_do_not_run_dependent_suites(self):
        for failure, dependent in [
            (COMPILE, (EATSBOT_SETUP, EATSBOT, FORMAT)),
            (SPRUCE_DB, (REGISTRY, PLAYWRIGHT, BROWSER)),
            (NODE, (WEB, PLAYWRIGHT, BROWSER)),
            (PLAYWRIGHT, (BROWSER,)),
        ]:
            with self.subTest(failure=failure):
                status, outcomes = self.simulate(failure)
                self.assertEqual(status, "failure")
                self.assert_outcomes(outcomes, "skipped", *dependent)

    def test_cancelled_run_stops_acceptance(self):
        status, outcomes = self.simulate(cancelled_after=SPRUCE)
        self.assertEqual(status, "cancelled")
        self.assert_outcomes(outcomes, "skipped", EATSBOT_SETUP, EATSBOT, FORMAT, REGISTRY, WEB, BROWSER)

    def test_failures_cannot_be_masked(self):
        self.assertNotIn("continue-on-error", self.job)
        self.assertNotIn("if", self.job)
        self.assertNotIn("needs", self.job)
        for step in self.job["steps"]:
            self.assertNotIn("continue-on-error", step)


if __name__ == "__main__":
    unittest.main()
