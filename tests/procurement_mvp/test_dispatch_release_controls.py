"""Negative controls for the combined runner; these are not worker acceptance."""
from copy import deepcopy
import json
from pathlib import Path
import tempfile
import unittest
import uuid
from unittest.mock import patch

import dispatch_release_acceptance as combined
import release_acceptance as release

REVISION = "a" * 40
ARTIFACT = "b" * 64
TENANT = "11111111-1111-1111-1111-111111111111"
LOAD = "22222222-2222-2222-2222-222222222222"
ASSIGNMENT = "33333333-3333-3333-3333-333333333333"
TRIP = {"tenant_id": TENANT, "order_id": "original-order", "load_id": LOAD, "assignment_id": ASSIGNMENT}
QUOTE = {"quote_id": "accepted-quote", "merchant_business_id": "original-supplier", "revision": 2,
         "total_minor": 12500, "currency": "USD", "expires_at_ms": 2000000000000, "source_ref": "original-source"}
DIGESTS = {"picked_up": "c" * 64, "delivered": "d" * 64}
PROOF = str(uuid.UUID(bytes=bytes.fromhex(DIGESTS["delivered"])[:16]))


def detail(revoked=False):
    steps = []
    for version, op in enumerate(("accept", "picked_up", "delivered")):
        payload = dict(TRIP, cooperative_id="acceptance-coop", op=op, automated=True, expected_version=version)
        if version:
            payload.update(proof_id=str(uuid.UUID(bytes=bytes.fromhex(DIGESTS[op])[:16])), proof_digest=DIGESTS[op])
        steps.append({"chapter_id": "acceptance-chapter", "payload": payload, "signer_count": 1,
                      "signature_count": 1, "signer_key_id": "acceptance-dispatch", "signer_role": "procurement_dispatch"})
    events = combined.PRE_CUSTODY_EVENTS + ["ProcurementDispatchStepV1"] * 3
    if revoked:
        events += ["ProcurementOperatorGrantedV1"]
    return {"ledger": {"global_seq": len(events), "verified_event_count": len(events),
                       "global_hash": ("f" if revoked else "e") * 64,
                       "grant_active": not revoked, "grant_version": 2 if revoked else 1,
                       "requests": [{"id": TRIP["order_id"], "dispatch_phase": "delivered",
                                     "phase": "fulfilled", "version": 7, "command_count": 6,
                                     "quote_revision": 2, "quote_total_minor": 12500,
                                     "payment_evidence_count": 0, "outcome_ref": "dispatch:" + PROOF}]},
            "requests": [{"chapter_id": "acceptance-chapter", "cooperative_id": "acceptance-coop",
                          "order_id": TRIP["order_id"], "accepted_quote": dict(QUOTE)}],
            "event_types": events, "steps": steps}


def receipt():
    return {"kind": combined.KIND, "execution_kind": combined.EXECUTION, "revision": REVISION,
            "artifact_sha256": ARTIFACT, "trust": "unsigned-runner-observation",
            "packaged_dispatch_worker": False, "live_delivery": False, "transport": dict(combined.TRANSPORT),
            "host_checks": {name: True for name in release.REQUIRED},
            "dispatch_checks": {name: True for name in combined.CHECKS},
            "restored_ledger": detail(revoked=True)["ledger"],
            "dispatch_evidence": {"source_revision": REVISION, "canonical_appender_in_dispatch": False,
                                  "canonical_delivery": detail(), "restored_delivery": detail(revoked=True),
                                  "assignment": dict(TRIP),
                                  "accepted_quote": dict(QUOTE), "handoff_code_sha256": dict(DIGESTS)}}


class BindingTests(unittest.TestCase):
    def validate(self, value):
        combined.validate_detail(value, TRIP, QUOTE, phase="delivered",
                                 operations=["accept", "picked_up", "delivered"], proof_digests=DIGESTS)

    def test_complete_binding(self):
        self.validate(detail())

    def test_in_transit_preserves_the_original_qualification_evidence(self):
        value = detail()
        value["steps"] = value["steps"][:2]
        value["event_types"] = value["event_types"][:-1]
        value["ledger"].update(global_seq=13, verified_event_count=13)
        row = value["ledger"]["requests"][0]
        row.update(dispatch_phase="in_transit", phase="accepted", version=6,
                   command_count=5, outcome_ref="original-qualification")
        args = dict(phase="in_transit", operations=["accept", "picked_up"], proof_digests=DIGESTS)
        with self.assertRaises(RuntimeError):
            combined.validate_detail(value, TRIP, QUOTE, **args)
        combined.validate_detail(value, TRIP, QUOTE, **args, prior_outcome_ref="original-qualification")
        for wrong in (None, "another-outcome"):
            row["outcome_ref"] = wrong
            with self.subTest(wrong=wrong), self.assertRaises(RuntimeError):
                combined.validate_detail(value, TRIP, QUOTE, **args, prior_outcome_ref="original-qualification")

    def test_each_original_quote_field_matters(self):
        for key in QUOTE:
            value = detail()
            value["requests"][0]["accepted_quote"][key] = "changed"
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                self.validate(value)

    def test_each_signed_step_binds_exact_order_and_sql_assignment(self):
        for index in range(3):
            for key in (*TRIP, "cooperative_id"):
                value = detail()
                value["steps"][index]["payload"][key] = "another"
                with self.subTest(index=index, key=key), self.assertRaises(RuntimeError):
                    self.validate(value)

    def test_other_scope_extra_order_and_wrong_outcome_refused(self):
        for mutate in (
            lambda value: value["requests"][0].update(chapter_id="another"),
            lambda value: value["requests"].append(deepcopy(value["requests"][0])),
            lambda value: value["ledger"]["requests"][0].update(outcome_ref="dispatch:" + LOAD),
            lambda value: value["ledger"]["requests"][0].update(payment_evidence_count=1),
            lambda value: value["event_types"].append("PaymentRecorded"),
            lambda value: value["event_types"].append("RestaurantDeliveryStepV1"),
        ):
            value = detail()
            mutate(value)
            with self.assertRaises(RuntimeError):
                self.validate(value)

    def test_duplicate_missing_and_reordered_steps_refused(self):
        for indexes in ((0, 1, 2, 2), (0, 2), (0, 2, 1)):
            value = detail()
            value["steps"] = [value["steps"][index] for index in indexes]
            with self.subTest(indexes=indexes), self.assertRaises(RuntimeError):
                self.validate(value)

    def test_extra_signer_signature_wrong_key_or_proof_refused(self):
        for field, replacement in (("signer_count", 2), ("signature_count", 2),
                                    ("signer_key_id", "rogue"), ("signer_role", "restaurant_dispatch")):
            value = detail()
            value["steps"][1][field] = replacement
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                self.validate(value)
        for key in ("proof_id", "proof_digest", "expected_version", "automated"):
            value = detail()
            value["steps"][2]["payload"][key] = "wrong"
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                self.validate(value)


class ReceiptTests(unittest.TestCase):
    def test_complete_receipt_and_legacy_receipt_remain_distinct(self):
        combined.validate_receipt(receipt(), REVISION, ARTIFACT)
        with self.assertRaises(RuntimeError):
            release.validate_receipt(receipt(), REVISION, ARTIFACT)

    def test_each_gate_required_and_truthy_non_boolean_refused(self):
        for section in ("host_checks", "dispatch_checks"):
            for name in receipt()[section]:
                for replacement in (None, False, "passed", 1):
                    value = receipt()
                    value[section][name] = replacement
                    with self.subTest(section=section, name=name, value=replacement), self.assertRaises(RuntimeError):
                        combined.validate_receipt(value, REVISION, ARTIFACT)
                value = receipt()
                del value[section][name]
                with self.assertRaises(RuntimeError):
                    combined.validate_receipt(value, REVISION, ARTIFACT)

    def test_wrong_revision_artifact_scope_and_execution_claims_refused(self):
        for key, wrong in (("revision", "c" * 40), ("artifact_sha256", "e" * 64),
                           ("kind", "procurement-packaged-acceptance-v1"), ("trust", "signed"),
                           ("execution_kind", "fully-packaged"), ("packaged_dispatch_worker", True),
                           ("live_delivery", True), ("transport", {})):
            value = receipt()
            value[key] = wrong
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                combined.validate_receipt(value, REVISION, ARTIFACT)

    def test_source_mismatch_or_forged_assignment_refused(self):
        for mutate in (
            lambda evidence: evidence.update(source_revision="e" * 40),
            lambda evidence: evidence.update(canonical_appender_in_dispatch=True),
            lambda evidence: evidence["assignment"].update(load_id=TENANT),
        ):
            value = receipt()
            mutate(value["dispatch_evidence"])
            with self.assertRaises(RuntimeError):
                combined.validate_receipt(value, REVISION, ARTIFACT)

    def test_incoherent_delivery_or_restore_evidence_refused(self):
        for mutate in (
            lambda value: value.pop("restored_ledger"),
            lambda value: value["restored_ledger"].update(grant_active=True),
            lambda value: value["dispatch_evidence"]["canonical_delivery"].update(event_types=[]),
            lambda value: value["dispatch_evidence"]["canonical_delivery"]["ledger"].update(global_seq=99),
            lambda value: value["dispatch_evidence"]["canonical_delivery"]["ledger"].update(verified_event_count=0),
            lambda value: value["dispatch_evidence"]["canonical_delivery"]["ledger"].update(global_hash="bad"),
            lambda value: value["dispatch_evidence"]["restored_delivery"]["ledger"].update(grant_version=1),
            lambda value: value["dispatch_evidence"]["restored_delivery"]["steps"][2]["payload"].update(proof_id=LOAD),
        ):
            value = receipt()
            mutate(value)
            with self.assertRaises(RuntimeError):
                combined.validate_receipt(value, REVISION, ARTIFACT)

    def test_stale_success_removed_before_failed_environment_guard(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory)
            target = destination / "receipt.json"
            target.write_text(json.dumps(receipt()))
            argv = ["dispatch_release_acceptance.py", "--archive", "missing.tar.gz", "--revision", REVISION,
                    "--receipts", str(destination), "--dispatch-project", "missing"]
            with patch("sys.argv", argv), patch.dict("os.environ", {}, clear=True), self.assertRaises(RuntimeError):
                combined.main()
            self.assertFalse(target.exists())


class IsolationTests(unittest.TestCase):
    def environment(self):
        return {"PROCUREMENT_DISPATCH_ACCEPTANCE": release.MODE,
                "DATABASE_URL": "ecto://dispatch:fixture@127.0.0.1:5432/dispatch_test", "PATH": "/usr/bin"}

    def test_private_inputs_are_written_without_group_or_world_access(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "private.json"
            combined.private_json(path, {"handoff_token": "synthetic-input"})
            self.assertEqual(json.loads(path.read_text()), {"handoff_token": "synthetic-input"})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            combined.private_json(path, {"action": "cleanup"})
            self.assertEqual(json.loads(path.read_text()), {"action": "cleanup"})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_peer_never_inherits_canonical_authority_or_unrelated_integrations(self):
        value = self.environment()
        secrets = {"EVENTSTORE_PASSWORD": "ledger", "PGDATABASE": "production", "PGSERVICE": "other",
                   "PROCUREMENT_SIGNING_SEED_HEX": "operator", "PROCUREMENT_GOVERNANCE_SEED_HEX": "governance",
                   "PROCUREMENT_SECRET_KEY_BASE": "session", "PROCUREMENT_LOGIN_SHA256": "login",
                   "RESTAURANT_DISPATCH_SEED_FILE": "/live/seed", "VOICE_API_KEY": "live"}
        value.update(secrets)
        result = combined.peer_environment(value)
        self.assertFalse(set(result) & set(secrets))
        self.assertEqual(result["DATABASE_URL"], value["DATABASE_URL"])
        self.assertEqual(result["PROCUREMENT_DISPATCH_AUTOMATED"], "false")

    def test_remote_existing_partitioned_or_unopted_database_refused(self):
        for key, wrong in (("PROCUREMENT_DISPATCH_ACCEPTANCE", ""), ("MIX_TEST_PARTITION", "1"),
                           ("DATABASE_URL", "ecto://dispatch:fixture@db.example:5432/dispatch_test"),
                           ("DATABASE_URL", "ecto://dispatch:fixture@127.0.0.1:5432/production"),
                           ("DATABASE_URL", "ecto://dispatch:fixture@127.0.0.1:5433/dispatch_test"),
                           ("DATABASE_URL", "ecto://dispatch:fixture@127.0.0.1:5432/dispatch_test?host=remote")):
            value = dict(self.environment(), **{key: wrong})
            with self.subTest(key=key, wrong=wrong), self.assertRaises(RuntimeError):
                combined.peer_environment(value)

    def test_offline_inspection_refused_beside_a_running_host(self):
        harness = release.Harness(Path("/unused"), Path("/unused"), Path("/unused"), {})
        harness.child = object()
        with self.assertRaises(RuntimeError):
            harness.fixture("inspect_dispatch")


if __name__ == "__main__":
    unittest.main()
