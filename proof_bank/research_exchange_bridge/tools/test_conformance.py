"""Negative controls ensure actual persisted output is part of acceptance."""
from copy import deepcopy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("bridge_conformance", Path(__file__).with_name("run_conformance.py"))
conformance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(conformance)


class PersistedResultTests(unittest.TestCase):
    def fixture(self):
        wire = conformance.base()
        result = conformance.model.decide(wire)
        receipt = {"payload": {"state_version": 1, "status": "accepted", "mathematical_acceptance": True,
                               "credit_issuance": False}}
        observation = {"state": deepcopy(result["state"]), "version": 1, "terminal": True, "outbox": "complete",
                       "receipt": receipt, "effects": [{"before_version": 0, "after_version": 1,
                                                         "kind": "accepted", "receipt_json": conformance.canonical(receipt).decode()}]}
        return wire, result, observation

    def test_actual_post_state_must_match(self):
        wire, result, observation = self.fixture()
        conformance.validate_observation(observation, wire, result)
        for field in ("balance_a", "balance_b", "escrow", "funder", "version", "payouts"):
            changed = deepcopy(observation)
            changed["state"][field] += 1
            with self.assertRaises(ValueError, msg=field):
                conformance.validate_observation(changed, wire, result)
        changed = deepcopy(observation)
        changed["state"]["binding"]["artifact_sha256"] = "substituted"
        with self.assertRaises(ValueError):
            conformance.validate_observation(changed, wire, result)
        for field in ("balance_a", "escrow", "payouts"):
            changed = deepcopy(observation)
            changed["state"][field] = bool(changed["state"][field])
            with self.assertRaises(ValueError, msg="Boolean counter: " + field):
                conformance.validate_observation(changed, wire, result)

    def test_split_or_duplicate_effect_and_receipt_refused(self):
        wire, result, observation = self.fixture()
        for field, value in (("version", 2), ("terminal", False), ("outbox", "pending")):
            changed = deepcopy(observation)
            changed[field] = value
            with self.assertRaises(ValueError):
                conformance.validate_observation(changed, wire, result)
        for field, value in (("before_version", 1), ("after_version", 2), ("kind", "rejected")):
            changed = deepcopy(observation)
            changed["effects"][0][field] = value
            with self.assertRaises(ValueError):
                conformance.validate_observation(changed, wire, result)
        changed = deepcopy(observation)
        changed["effects"] *= 2
        with self.assertRaises(ValueError):
            conformance.validate_observation(changed, wire, result)


if __name__ == "__main__":
    unittest.main()
