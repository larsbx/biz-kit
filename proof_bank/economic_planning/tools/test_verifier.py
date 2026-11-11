#!/usr/bin/env python3
"""Adversarial controls for the planning verification receipt gate.

These synthetic logs test classification of tool outcomes. They are not Lean
proofs or model-checking evidence, and deliberately do not execute either tool.
The acceptance runner separately exercises real compiler/model counterexamples.
"""
from __future__ import annotations

import importlib.util
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True

SPEC = importlib.util.spec_from_file_location(
    "economic_planning_verifier", Path(__file__).with_name("verify.py")
)
assert SPEC is not None and SPEC.loader is not None
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)

VERSION = "0.56.0"
IDENTITY = f"# APALACHE version: {VERSION} | build: synthetic-test-fixture\n"
SAFE = (
    IDENTITY
    + "Model checking completed. No error has been found.\n"
    + "158 states generated, 37 distinct states found, 0 states left on queue.\n"
    + "The depth of the complete state graph search is 6.\n"
)
COUNTEREXAMPLE = (
    IDENTITY
    + "Error: Invariant q_inv is violated.\n"
    + "Error: The behavior up to this point is:\n"
    + "State 1: <Initial predicate>\n"
    + "/\\ s = [operation |-> 17, allocations |-> <<>>]\n"
    + "State 2: <Next-state action>\n"
    + "/\\ s = [operation |-> 18, allocations |-> <<>>]\n"
    + "[violation] Found an issue\n"
)


class IdentifierControls(unittest.TestCase):
    def test_nonempty_qualified_inventory_is_accepted(self):
        names = ["EconomicPlanning.source_available", "trace_preserves_capacity"]
        self.assertEqual(VERIFY.unique_names(names, "fixture"), names)

    def test_empty_duplicate_and_unsafe_inventories_are_rejected(self):
        invalid = [
            None, "A", [], [""], ["A", "A"], [None], [["A"]],
            ["A B"], ["A\nB"], ["A;B"], [".A"], ["A."], ["A..B"],
        ]
        for names in invalid:
            with self.subTest(names=names), self.assertRaises(ValueError):
                VERIFY.unique_names(names, "fixture")


class AxiomControls(unittest.TestCase):
    targets = ["EconomicPlanning.first", "EconomicPlanning.second"]
    log = (
        "'EconomicPlanning.first' depends on axioms: [propext,\n"
        " Classical.choice, Quot.sound]\n"
        "'EconomicPlanning.second' does not depend on any axioms\n"
    )

    def test_complete_standard_axiom_closure_is_accepted(self):
        result = VERIFY.parse_axioms(self.log, self.targets)
        self.assertEqual(set(result), set(self.targets))
        self.assertEqual(set(result[self.targets[0]]), VERIFY.ALLOWED_AXIOMS)
        self.assertEqual(result[self.targets[1]], [])

    def test_missing_extra_duplicate_and_malformed_results_are_rejected(self):
        extra = "'EconomicPlanning.extra' does not depend on any axioms\n"
        invalid = [
            "", self.log.split("'EconomicPlanning.second'")[0],
            self.log + extra, self.log + self.log,
            self.log.replace("[propext,", "[propext,").replace("Quot.sound]", "Quot.sound"),
        ]
        for log in invalid:
            with self.subTest(log=log), self.assertRaises(ValueError):
                VERIFY.parse_axioms(log, self.targets)

    def test_empty_and_duplicate_targets_cannot_weaken_parser(self):
        for log, names in [("", []), (self.log, self.targets + self.targets), ("", [""])]:
            with self.subTest(names=names), self.assertRaises(ValueError):
                VERIFY.parse_axioms(log, names)

    def test_every_nonstandard_axiom_is_rejected(self):
        for axiom in [
            "sorryAx", "Lean.trustCompiler", "EconomicPlanning.assumeSafe",
            "native_decide_fresh_unapproved_axiom", "False.elim_axiom",
        ]:
            log = self.log.replace("propext,", f"propext, {axiom},")
            with self.subTest(axiom=axiom), self.assertRaisesRegex(ValueError, "unapproved"):
                VERIFY.parse_axioms(log, self.targets)


class NamespaceAuditControls(unittest.TestCase):
    targets = ["EconomicPlanning.capacity_safe"]
    log = (
        "DECL EconomicPlanning.capacity_safe theorem\n"
        "AXIOMS EconomicPlanning.capacity_safe [propext]\n"
        "DECL EconomicPlanning.SignalKey.rec generated\n"
        "AXIOMS EconomicPlanning.SignalKey.rec []\n"
        "DECL EconomicPlanning.allocate declaration\n"
        "AXIOMS EconomicPlanning.allocate [Classical.choice,Quot.sound]\n"
        "AUDIT_DECLARATIONS 3\n"
        "AUDIT_THEOREMS 1\n"
    )

    def test_complete_namespace_includes_generated_dependency_closures(self):
        result = VERIFY.parse_declaration_audit(self.log, self.targets)
        self.assertEqual(result["declaration_count"], 3)
        self.assertEqual(result["theorem_count"], 1)
        self.assertEqual(result["dependencies"]["EconomicPlanning.SignalKey.rec"], [])
        self.assertEqual(set(result["dependencies"]["EconomicPlanning.allocate"]),
                         {"Classical.choice", "Quot.sound"})

    def test_omitted_or_duplicate_declarations_and_closures_are_rejected(self):
        declaration = "DECL EconomicPlanning.SignalKey.rec generated\n"
        closure = "AXIOMS EconomicPlanning.SignalKey.rec []\n"
        invalid = [
            "", self.log.replace(declaration, ""), self.log.replace(closure, ""),
            self.log.replace(declaration + closure, ""),
            self.log + declaration, self.log + closure,
            self.log.replace("capacity_safe theorem", "capacity_safe generated"),
        ]
        for log in invalid:
            with self.subTest(log=log), self.assertRaises(ValueError):
                VERIFY.parse_declaration_audit(log, self.targets)

    def test_forged_duplicate_or_missing_inventory_counts_are_rejected(self):
        invalid = [
            self.log.replace("AUDIT_DECLARATIONS 3", "AUDIT_DECLARATIONS 2"),
            self.log.replace("AUDIT_THEOREMS 1", "AUDIT_THEOREMS 0"),
            self.log.replace("AUDIT_DECLARATIONS 3\n", ""),
            self.log.replace("AUDIT_THEOREMS 1\n", ""),
            self.log + "AUDIT_DECLARATIONS 3\n", self.log + "AUDIT_THEOREMS 1\n",
        ]
        for log in invalid:
            with self.subTest(log=log), self.assertRaises(ValueError):
                VERIFY.parse_declaration_audit(log, self.targets)

    def test_unregistered_axioms_in_generated_or_ordinary_declarations_are_rejected(self):
        invalid = [
            self.log.replace("AXIOMS EconomicPlanning.SignalKey.rec []",
                             "AXIOMS EconomicPlanning.SignalKey.rec [sorryAx]"),
            self.log.replace("Classical.choice,Quot.sound", "EconomicPlanning.unsafeAssumption"),
            self.log.replace("allocate declaration", "allocate axiom"),
            self.log.replace("EconomicPlanning.SignalKey.rec", "Foreign.SignalKey.rec"),
        ]
        for log in invalid:
            with self.subTest(log=log), self.assertRaises(ValueError):
                VERIFY.parse_declaration_audit(log, self.targets)


class ModelOutcomeControls(unittest.TestCase):
    def rejected(self, log: str, code: int, negative: bool):
        with self.assertRaises(ValueError):
            VERIFY.model_result(log, code, VERSION, negative)

    def test_completed_nonempty_finite_graph_is_accepted(self):
        result = VERIFY.model_result(SAFE, 0, VERSION, False)
        self.assertEqual(result, {
            "result": "complete_finite_graph", "generated": 158,
            "distinct": 37, "queued": 0, "depth": 6,
        })

    def test_actual_invariant_state_trace_is_accepted(self):
        self.assertEqual(
            VERIFY.model_result(COUNTEREXAMPLE, 1, VERSION, True),
            {"result": "expected_invariant_counterexample"},
        )

    def test_missing_or_wrong_translator_identity_is_rejected(self):
        for text, code, negative in [(SAFE, 0, False), (COUNTEREXAMPLE, 1, True)]:
            for log in [text.replace(IDENTITY, ""), text.replace(VERSION, "0.0.0")]:
                with self.subTest(negative=negative, log=log):
                    self.rejected(log, code, negative)

    def test_exit_code_is_part_of_both_outcome_contracts(self):
        for code in [1, 2, -9, 124]:
            with self.subTest(positive_exit=code):
                self.rejected(SAFE, code, False)
        for code in [0, 2, -9, 124]:
            with self.subTest(negative_exit=code):
                self.rejected(COUNTEREXAMPLE, code, True)

    def test_incomplete_or_bounded_search_is_not_complete_evidence(self):
        invalid = [
            SAFE.replace("0 states left on queue", "12 states left on queue"),
            SAFE.replace("158 states generated, 37 distinct states found, 0 states left on queue.\n", ""),
            SAFE.replace("The depth of the complete state graph search is 6.\n", ""),
            SAFE.replace("Model checking completed. No error has been found.\n", ""),
            IDENTITY + "No error found up to depth 6.\n37 states explored.\n",
            SAFE.replace("158 states generated, 37 distinct states found", "0 states generated, 0 distinct states found"),
            SAFE.replace("158 states generated, 37 distinct states found", "3 states generated, 37 distinct states found"),
        ]
        for log in invalid:
            with self.subTest(log=log):
                self.rejected(log, 0, False)

    def test_expected_negative_needs_exact_invariant_and_nonempty_trace(self):
        invalid = [
            COUNTEREXAMPLE.replace("Invariant q_inv", "Invariant another_property"),
            COUNTEREXAMPLE.replace("Error: Invariant q_inv is violated.\n", ""),
            COUNTEREXAMPLE.replace("Error: The behavior up to this point is:\n", ""),
            COUNTEREXAMPLE.replace("[violation] Found an issue\n", ""),
            IDENTITY + "Error: Invariant q_inv is violated.\n"
            + "Error: The behavior up to this point is:\n[violation] Found an issue\n",
            IDENTITY + "Error: Invariant q_inv is violated.\n"
            + "Error: The behavior up to this point is:\nState 1:\n"
            + "[violation] Found an issue\n",
        ]
        for log in invalid:
            with self.subTest(log=log):
                self.rejected(log, 1, True)

    def test_failure_without_a_counterexample_is_never_a_negative_pass(self):
        failures = [
            "RUNNER_TIMEOUT", "Error: Deadlock reached.",
            "Error: Parsing or semantic analysis failed.",
            "Error: The invariant q_inv is not a state predicate.",
            "Error: TLC threw an unexpected exception.",
            "java.lang.OutOfMemoryError: Java heap space",
            "Error: No initial states generated.",
            "[error] Failed to translate Quint module",
        ]
        for failure in failures:
            with self.subTest(failure=failure):
                self.rejected(IDENTITY + failure + "\n", 1, True)

    def test_failure_markers_cannot_be_hidden_by_successful_fragments(self):
        failures = [
            "RUNNER_TIMEOUT", "Error: Deadlock reached.",
            "Error: Parsing or semantic analysis failed.",
            "Error: TLC threw an unexpected exception.",
            "java.lang.OutOfMemoryError: Java heap space",
            "Error: No initial states generated.",
            "[error] Failed to translate Quint module",
        ]
        for failure in failures:
            for text, code, negative in [(SAFE, 0, False), (COUNTEREXAMPLE, 1, True)]:
                with self.subTest(failure=failure, negative=negative):
                    self.rejected(text + failure + "\n", code, negative)

    def test_positive_result_cannot_also_contain_invariant_violation(self):
        self.rejected(SAFE + COUNTEREXAMPLE, 0, False)


class ExactSourceControls(unittest.TestCase):
    """Exercise real Git index flags; clean porcelain output is insufficient."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="planning-source-control-")
        self.addCleanup(temporary.cleanup)
        self.repo = Path(temporary.name)
        self.source = self.repo / "Proof.lean"
        self.committed = b"theorem example_verified : True := True.intro\n"
        self.source.write_bytes(self.committed)
        self.git("init", "--quiet")
        self.git("config", "user.name", "Planning Verifier Test")
        self.git("config", "user.email", "planning-verifier@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "core.hooksPath", "/dev/null")
        self.git("add", "Proof.lean")
        self.git("commit", "--quiet", "-m", "Synthetic source fixture")
        for attribute, value in [("REPO", self.repo), ("SOURCE_PATHS", ["Proof.lean"])]:
            replacement = patch.object(VERIFY, attribute, value)
            replacement.start()
            self.addCleanup(replacement.stop)

    def git(self, *arguments: str) -> str:
        return subprocess.check_output(
            ["git", "-C", str(self.repo), *arguments],
            stderr=subprocess.PIPE, text=True,
        ).strip()

    def test_committed_source_is_accepted(self):
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual(VERIFY.inventory(), {
            "Proof.lean": hashlib.sha256(self.committed).hexdigest(),
        })

    def test_assume_unchanged_cannot_hide_altered_proof(self):
        self.git("update-index", "--assume-unchanged", "Proof.lean")
        self.source.write_text("axiom example_verified : False\n")
        self.assertEqual(self.git("status", "--porcelain"), "")
        with self.assertRaisesRegex(ValueError, "source bytes differ from HEAD"):
            VERIFY.inventory()

    def test_skip_worktree_cannot_hide_altered_proof(self):
        self.git("update-index", "--skip-worktree", "Proof.lean")
        self.source.write_text("axiom example_verified : False\n")
        self.assertEqual(self.git("status", "--porcelain"), "")
        with self.assertRaisesRegex(ValueError, "source bytes differ from HEAD"):
            VERIFY.inventory()

    def test_staged_replacement_is_not_the_committed_source(self):
        self.source.write_text("axiom example_verified : False\n")
        self.git("add", "Proof.lean")
        self.assertNotEqual(self.git("status", "--porcelain"), "")
        with self.assertRaisesRegex(ValueError, "source bytes differ from HEAD"):
            VERIFY.inventory()

    def test_new_staged_source_requires_a_commit(self):
        (self.repo / "New.lean").write_text("theorem another : True := True.intro\n")
        self.git("add", "New.lean")
        with patch.object(VERIFY, "SOURCE_PATHS", ["Proof.lean", "New.lean"]):
            with self.assertRaisesRegex(ValueError, "source is not committed at HEAD"):
                VERIFY.inventory()


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromModule(__import__(__name__))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if result.wasSuccessful():
        print("VERIFIER_CONTROLS_PASSED")
    raise SystemExit(0 if result.wasSuccessful() else 1)
