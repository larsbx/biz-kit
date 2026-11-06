from __future__ import annotations

import unittest

from check_proofs import parse_axioms


class AxiomGateTests(unittest.TestCase):
    def test_standard_axioms_and_empty_dependencies(self):
        result = parse_axioms("'A' depends on axioms: [propext,\n Classical.choice, Quot.sound]\n"
                              "'B' does not depend on any axioms\n", ["A", "B"])
        self.assertEqual(result["B"], [])
        self.assertEqual(len(result["A"]), 3)

    def test_missing_result_rejected(self):
        with self.assertRaisesRegex(ValueError, "incomplete axiom audit"):
            parse_axioms("", ["expected"])

    def test_duplicates_rejected(self):
        with self.assertRaisesRegex(ValueError, "duplicate"):
            parse_axioms("'A' does not depend on any axioms\n" * 2, ["A"])

    def test_all_unapproved_axiom_names_rejected(self):
        for name in ["sorryAx", "Lean.trustCompiler", "arbitraryNewNativeComputationAxiom", "project.invented"]:
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "unapproved axioms"):
                parse_axioms(f"'A' depends on axioms: [{name}]", ["A"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
