"""Negative controls for the independent, test-only wire oracle."""
import copy
import json
from pathlib import Path
import subprocess
import unittest

import gossip_reference as ref

FIXTURE = Path(__file__).parent.parent / "vectors/gossip_wire_v1.json"


class ReferenceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bundle = json.loads(FIXTURE.read_text(encoding="utf-8"))

    def test_fixture_signatures_transcripts_and_commitments(self):
        ref.check_bundle(self.bundle)

    def test_reproducible_without_elixir_or_application_code(self):
        self.assertEqual(ref.generate(), self.bundle)

    def test_every_profile_rejects_signature_tampering(self):
        for vector in self.bundle["messages"]:
            with self.subTest(vector=vector["name"]):
                m = json.loads(vector["wire"])
                m["announcement"] = "ff" * 16
                with self.assertRaises(subprocess.CalledProcessError):
                    ref.verify(json.dumps(m), self.bundle["pins"][vector["actor"]])

    def test_pin_is_supplied_independently(self):
        for vector in self.bundle["messages"]:
            with self.assertRaises(ValueError):
                ref.verify(vector["wire"], "00" * 32)

    def test_duplicate_keys_at_any_depth_and_invalid_json_refuse(self):
        for raw in ['{"a":1,"a":2}', '{"a":{"b":1,"b":2}}', '{"a":NaN}', b'{"a":"\xff"}', "[]"]:
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                ref.decode(raw)

    def test_depth_and_size_are_bounded_before_parsing(self):
        for raw in ['{"a":' * 17 + '0' + '}' * 17, '{"a":"' + 'x' * 65536 + '"}']:
            with self.assertRaises(ValueError):
                ref.decode(raw)
        self.assertEqual(ref.decode('{"a":"[\\\"{}]"}'), {"a": '["{}]'})

    def test_noncanonical_value_types_refuse(self):
        for value in [1.5, float("inf"), {1: "non-string"}, {"s": "\ud800"}]:
            with self.assertRaises((ValueError, UnicodeError)):
                ref.canonical(value)
        self.assertNotEqual(ref.canonical(True), ref.canonical(1))
        self.assertNotEqual(ref.canonical("é"), ref.canonical("e\u0301"))

    def test_unknown_profiles_and_extra_fields_refuse(self):
        m = json.loads(self.bundle["messages"][0]["wire"])
        for changed in [dict(m, schema="unknown"), dict(m, command="reserve")]:
            with self.assertRaises(ValueError):
                ref.transcript(changed)

    def test_commitments_are_checked_independently_of_signatures(self):
        for field in ("topic", "content_hash", "transcript_hex"):
            bundle = copy.deepcopy(self.bundle)
            target = bundle if field == "topic" else bundle["messages"][0]
            target[field] = "00"
            with self.subTest(field=field), self.assertRaises(ValueError):
                ref.check_bundle(bundle)

    def test_validly_resigned_offer_with_wrong_batch_refuses(self):
        bundle = copy.deepcopy(self.bundle)
        vector = next(v for v in bundle["messages"] if v["name"] == "offer")
        m = json.loads(vector["wire"])
        m["entries"][0]["hash"] = "ff" * 32
        seed = bytes.fromhex(bundle["test_seeds"][vector["actor"]])
        changed = ref.sign(m, seed)
        vector["wire"] = json.dumps(changed)
        vector["transcript_hex"] = ref.transcript(changed).hex()
        # Signature is valid; the retained batch commitment is not.
        ref.verify(vector["wire"], bundle["pins"][vector["actor"]])
        with self.assertRaisesRegex(ValueError, "batch mismatch"):
            ref.check_bundle(bundle)


if __name__ == "__main__":
    unittest.main()
