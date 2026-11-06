import unittest
import hashlib
from pathlib import Path
from tempfile import TemporaryDirectory
from importlib.util import module_from_spec, spec_from_file_location

source = Path(__file__).resolve().parents[1] / "proof_bank_characterization_audit.py"
spec = spec_from_file_location("proof_bank_characterization_audit", source)
module = module_from_spec(spec)
spec.loader.exec_module(module)

class AuditTest(unittest.TestCase):
    def test_drift_and_fake_promotion_fail_closed(self):
        with TemporaryDirectory() as d:
            root = Path(d)
            (root / "apps/foo").mkdir(parents=True)
            (root / "apps/foo/mix.exs").write_text("foo")
            (root / "mix.exs").write_text("umbrella")
            def blob(p):
                content = (root / p).read_bytes()
                return hashlib.sha1(b"blob " + str(len(content)).encode() + b"\0" + content).hexdigest()
            base = dict(schema="biz-kit.proof-bank.characterization.v1",
                        source_sha="sha", intended_purpose="test",
                        first_formal_obligation="test", first_formal_layer="L1",
                        observed_code_paths=["apps/foo/mix.exs"], evidence_git_blobs={"apps/foo/mix.exs":blob("apps/foo/mix.exs")}, **module.STATES)
            data = dict(schema=module.SCHEMA, source_sha="sha",
                        records=[dict(base,id="foo"),
                                 dict(base,id="biz-kit", observed_code_paths=["mix.exs"], evidence_git_blobs={"mix.exs":blob("mix.exs")})])
            self.assertEqual([], module.audit(root, data))
            altered = {**data, "records": [dict(base,id="foo", proof_status="proven"),
                                          dict(base,id="biz-kit", observed_code_paths=["mix.exs"])]}
            self.assertIn("invalid status", str(module.audit(root, altered)))
            self.assertIn("app drift", str(module.audit(root, {**data, "records": [data["records"][0]]})))
            self.assertIn("changed source/test bytes", str(module.audit(root, {
                **data, "records": [dict(base,id="foo",evidence_git_blobs={"apps/foo/mix.exs":"0"*40}),data["records"][1]]
            })))
            self.assertIn("missing/unsafe", str(module.audit(root, {**data, "records": [dict(base,id="foo", observed_code_paths=["../secret"]), data["records"][1]]})))

class RefreshTest(unittest.TestCase):
    def setUp(self):
        self.dir = TemporaryDirectory()
        self.root = root = Path(self.dir.name)
        (root / "apps/foo").mkdir(parents=True)
        (root / "apps/foo/mix.exs").write_text("foo")
        (root / "mix.exs").write_text("umbrella")
        base = dict(schema="biz-kit.proof-bank.characterization.v1", source_sha="sha",
                    intended_purpose="test", first_formal_obligation="test", first_formal_layer="L1",
                    **module.STATES)
        self.data = dict(schema=module.SCHEMA, source_sha="sha", records=[
            dict(base, id="foo", observed_code_paths=["apps/foo/mix.exs"],
                 evidence_git_blobs={"apps/foo/mix.exs": module.git_blob(root / "apps/foo/mix.exs")}),
            dict(base, id="biz-kit", observed_code_paths=["mix.exs"],
                 evidence_git_blobs={"mix.exs": module.git_blob(root / "mix.exs")})])

    def tearDown(self):
        self.dir.cleanup()

    def test_refresh_repins_changed_bytes_and_logs_it(self):
        (self.root / "apps/foo/mix.exs").write_text("foo, edited")
        self.assertIn("changed source/test bytes", str(module.audit(self.root, self.data)))
        refreshed = module.refresh(self.root, self.data, "abc123", "2026-11-03")
        self.assertEqual([], module.audit(self.root, refreshed))
        [entry] = refreshed["evidence_refreshes"]
        self.assertEqual(("abc123", "2026-11-03", ["apps/foo/mix.exs"]),
                         (entry["at_sha"], entry["date"], entry["refreshed_paths"]))
        self.assertEqual("sha", refreshed["source_sha"], "a refresh is not a re-characterization")
        self.assertNotIn("evidence_refreshes", self.data, "the input is not mutated")

    def test_refresh_without_changes_is_identity(self):
        self.assertEqual(self.data, module.refresh(self.root, self.data, "abc123", "2026-11-03"))

    def test_refresh_refuses_non_string_and_escaping_symlink_paths(self):
        self.assertFalse(module.safe_file(self.root, None))
        self.assertFalse(module.safe_file(self.root, 123))
        with TemporaryDirectory() as outside:
            secret = Path(outside) / "secret"
            secret.write_text("outside the reviewed checkout")
            (self.root / "escaped").symlink_to(outside, target_is_directory=True)
            path = "escaped/secret"
            self.assertFalse(module.safe_file(self.root, path))
            unsafe = dict(self.data["records"][0], observed_code_paths=[path],
                          evidence_git_blobs={path: "0" * 40})
            data = {**self.data, "records": [unsafe, self.data["records"][1]]}
            refreshed = module.refresh(self.root, data, "abc123", "2026-11-03")
            self.assertEqual(data, refreshed)
            self.assertIn("missing/unsafe", str(module.audit(self.root, refreshed)))

    def test_refresh_never_hides_drift_missing_paths_or_promotion(self):
        (self.root / "apps/bar").mkdir()
        (self.root / "apps/bar/mix.exs").write_text("bar")
        promoted = dict(self.data["records"][0], proof_status="proven",
                        observed_code_paths=["apps/foo/gone.ex"], evidence_git_blobs={"apps/foo/gone.ex": "0" * 40})
        data = {**self.data, "records": [promoted, self.data["records"][1]]}
        problems = str(module.audit(self.root, module.refresh(self.root, data, "abc123", "2026-11-03")))
        for kept in ("app drift", "invalid status", "missing/unsafe"):
            self.assertIn(kept, problems)
