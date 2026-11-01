import unittest
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
            base = dict(schema="biz-kit.proof-bank.characterization.v1",
                        source_sha="sha", intended_purpose="test",
                        first_formal_obligation="test", first_formal_layer="L1",
                        observed_code_paths=["apps/foo/mix.exs"], **module.STATES)
            data = dict(schema=module.SCHEMA, source_sha="sha",
                        records=[dict(base,id="foo"),
                                 dict(base,id="biz-kit", observed_code_paths=["mix.exs"])])
            self.assertEqual([], module.audit(root, data))
            altered = {**data, "records": [dict(base,id="foo", proof_status="proven"),
                                          dict(base,id="biz-kit", observed_code_paths=["mix.exs"])]}
            self.assertIn("invalid status", str(module.audit(root, altered)))
            self.assertIn("app drift", str(module.audit(root, {**data, "records": [data["records"][0]]})))
            self.assertIn("missing/unsafe", str(module.audit(root, {**data, "records": [dict(base,id="foo", observed_code_paths=["../secret"]), data["records"][1]]})))
