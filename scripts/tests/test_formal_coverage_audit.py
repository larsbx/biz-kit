import json
import unittest
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
from tempfile import TemporaryDirectory

source = Path(__file__).resolve().parents[1] / "formal_coverage_audit.py"
spec = spec_from_file_location("formal_coverage_audit", source)
module = module_from_spec(spec)
spec.loader.exec_module(module)

LEAN = "theorem good_safe : True := trivial\n"
QUINT = ("module m {\n  val obligation = true\n  val obligationWitness = false\n}\n"
         "module m_control {\n  import m.*\n}\n")


class AuditTest(unittest.TestCase):
    def setUp(self):
        self.dir = TemporaryDirectory()
        self.root = root = Path(self.dir.name)
        (root / "formal/lean").mkdir(parents=True)
        (root / "formal/quint").mkdir(parents=True)
        (root / "formal/lean/Good.lean").write_text(LEAN)
        (root / "formal/lean/lakefile.toml").write_text('defaultTargets = ["Good"]\n')
        (root / "formal/lean/check.sh").write_text("for root in Good; do audit; done\n")
        (root / "formal/quint/m.qnt").write_text(QUINT)
        self.ids = ["a", "b", "c"]
        self.coverage = {
            "schema": module.SCHEMA,
            "covered": {
                "a": [{"lean": "Good", "theorem": "good_safe"}],
                "b": [{"quint": "formal/quint/m.qnt", "invariant": "obligation",
                       "witness": "obligationWitness"}],
            },
            "uncovered": ["c"],
        }

    def tearDown(self):
        self.dir.cleanup()

    def audit(self, coverage=None, base=None):
        return module.audit(self.root, self.ids, coverage or self.coverage, base)

    def test_consistent_registry_passes(self):
        self.assertEqual([], self.audit())
        self.assertEqual((2, 3), module.ratio(self.coverage, self.ids))

    def test_every_catalog_app_is_accounted_for_exactly_once(self):
        self.assertIn("unaccounted: ['c']", str(self.audit({**self.coverage, "uncovered": []})))
        both = {**self.coverage, "uncovered": ["a", "c"]}
        self.assertIn("both covered and uncovered: ['a']", str(self.audit(both)))
        extra = {**self.coverage, "uncovered": ["c", "zz"]}
        self.assertIn("not in the catalog: ['zz']", str(self.audit(extra)))

    def test_lean_theorem_must_exist_in_a_built_and_audited_module(self):
        missing = {**self.coverage, "covered": {**self.coverage["covered"],
                   "a": [{"lean": "Good", "theorem": "absent"}]}}
        self.assertIn("a: theorem absent not declared in formal/lean/Good.lean", str(self.audit(missing)))
        (self.root / "formal/lean/lakefile.toml").write_text("defaultTargets = []\n")
        (self.root / "formal/lean/check.sh").write_text("")
        problems = str(self.audit())
        self.assertIn("a: module Good is not a lake default target", problems)
        self.assertIn("a: module Good is not axiom-audited by formal/lean/check.sh", problems)

    def test_quint_invariant_and_witness_must_be_declared(self):
        bad = {**self.coverage, "covered": {**self.coverage["covered"],
               "b": [{"quint": "formal/quint/m.qnt", "invariant": "absent"}]}}
        problems = str(self.audit(bad))
        self.assertIn("b: val absent not declared", problems)
        self.assertIn("b: a Quint entry needs a non-vacuity witness", problems)
        unsafe = {**self.coverage, "covered": {**self.coverage["covered"],
                  "b": [{"quint": "../m.qnt", "invariant": "obligation", "witness": "obligationWitness"}]}}
        self.assertIn("b: unsafe or missing model path ../m.qnt", str(self.audit(unsafe)))

    def test_covered_app_needs_at_least_one_artifact(self):
        empty = {**self.coverage, "covered": {**self.coverage["covered"], "a": []}}
        self.assertIn("a: covered without an artifact", str(self.audit(empty)))

    def test_ratchet_uncovered_may_only_shrink(self):
        base = {**self.coverage, "covered": {"a": self.coverage["covered"]["a"]}, "uncovered": ["b", "c"]}
        self.assertEqual([], self.audit(base=base))
        regressed = {**self.coverage, "covered": {"b": self.coverage["covered"]["b"]}, "uncovered": ["a", "c"]}
        self.assertIn("ratchet: newly uncovered ['a']", str(self.audit(regressed, base=self.coverage)))

    def test_quint_main_and_control_modules_must_exist(self):
        entry = {"quint": "formal/quint/m.qnt", "main": "m", "control": "m_control",
                 "invariant": "obligation", "witness": "obligationWitness"}
        ok = {**self.coverage, "covered": {**self.coverage["covered"], "b": [entry]}}
        self.assertEqual([], self.audit(ok))
        bad = {**self.coverage, "covered": {**self.coverage["covered"],
               "b": [{**entry, "main": "nope", "control": "gone"}]}}
        problems = str(self.audit(bad))
        self.assertIn("b: module nope not declared", problems)
        self.assertIn("b: module gone not declared", problems)

    def test_obligation_models_require_a_negative_control(self):
        (self.root / "formal/quint/obligations").mkdir()
        (self.root / "formal/quint/obligations/m.qnt").write_text(QUINT)
        entry = {"quint": "formal/quint/obligations/m.qnt", "main": "m",
                 "invariant": "obligation", "witness": "obligationWitness"}
        cov = {**self.coverage, "covered": {**self.coverage["covered"], "b": [entry]}}
        self.assertIn("b: an obligation model needs a negative control module", str(self.audit(cov)))

    def test_quint_checks_lists_each_artifact_once(self):
        entry = {"quint": "formal/quint/m.qnt", "main": "m", "control": "m_control",
                 "invariant": "obligation", "witness": "obligationWitness"}
        cov = {**self.coverage, "covered": {"b": [entry, entry]}}
        self.assertEqual([("formal/quint/m.qnt", "m", "m_control", "obligation", "obligationWitness", 6)],
                         module.quint_checks(cov))
        self.assertEqual([("formal/quint/m.qnt", "-", "-", "obligation", "obligationWitness", 6)],
                         module.quint_checks(self.coverage))


if __name__ == "__main__":
    unittest.main()


class BaseRefTest(unittest.TestCase):
    def setUp(self):
        import subprocess
        self.dir = TemporaryDirectory()
        self.root = Path(self.dir.name)
        self.git = lambda *a: subprocess.run(["git", "-C", str(self.root), *a], check=True,
                                             capture_output=True, text=True)
        self.git("init", "-q")
        self.git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "bootstrap")

    def tearDown(self):
        self.dir.cleanup()

    def test_invalid_ref_fails_closed(self):
        base, problem = module.load_base(self.root, "refs/does-not-exist")
        self.assertIsNone(base)
        self.assertIn("cannot resolve ratchet base refs/does-not-exist", problem)

    def test_existing_commit_without_coverage_is_bootstrap(self):
        self.assertEqual((None, None), module.load_base(self.root, "HEAD"))

    def test_existing_coverage_is_loaded_and_bad_json_fails(self):
        (self.root / "formal").mkdir()
        (self.root / "formal/coverage.json").write_text('{"uncovered": ["a"]}')
        self.git("add", ".")
        self.git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "cov")
        self.assertEqual(({"uncovered": ["a"]}, None), module.load_base(self.root, "HEAD"))
        (self.root / "formal/coverage.json").write_text("{not json")
        self.git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qam", "bad")
        base, problem = module.load_base(self.root, "HEAD")
        self.assertIsNone(base)
        self.assertIn("unreadable ratchet base", problem)
