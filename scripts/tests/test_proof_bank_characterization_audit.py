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
