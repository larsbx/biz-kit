"""Deterministic, offline acceptance through the unchanged public adapter."""
import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

from . import wire
from .admission import AdmissionStore, observation_mac
from .boundary import HostIdentity, PlanningError, SourceUnavailable, TraceRejected


# Public synthetic keys and deliberately artificial timestamps.
KEYS = {provider: bytes([index]) * 32 for index, provider in enumerate(
    ("port", "seller", "broker", "research"), start=1,
)}
SCOPE = "synthetic-harbor"
MEMBER = HostIdentity("analyst", SCOPE)
SERIES = ("harbor/capacity", "fuel/primary", "fuel/alternate", "rates/indicator")
PROVIDERS = dict(zip(SERIES, KEYS))
VALUES = dict(zip(SERIES, ("10", "300", "320", "-0.25")))
GRANTS = [(MEMBER.principal, SCOPE, source, "r1") for source in SERIES]


def encode(value):
    return json.dumps(value, separators=(",", ":")).encode()


def observation(source, **updates):
    payload = {
        "schema": "biz-kit/economic-planning/synthetic-observation-v1",
        "provider": PROVIDERS[source], "ref": {"source": source, "revision": "r1"},
        "publishedAt": "9", "effectiveFrom": "20", "effectiveUntil": "23",
        "value": VALUES[source],
    }
    payload.update(updates)
    raw = encode(payload)
    return raw, observation_mac(KEYS[PROVIDERS[source]], raw), "10"


def request(snapshot, *, second_quote=False):
    capacity = {
        "family": "dispatch", "measure": "physicalQuantity", "subject": "cargo-space",
        "material": "produce", "grade": "A", "form": "packed", "unit": "kg",
        "currency": "", "location": "harbor-a", "instrument": "physical", "maturity": None,
    }
    fuel = {
        **capacity, "family": "fuel", "measure": "moneyMinorUnits", "subject": "delivered-charge",
        "material": "jet-fuel", "grade": "Jet A-1", "form": "liquid", "unit": "minor-unit",
        "currency": "USD",
    }
    rate = {
        **capacity, "family": "centralBank", "measure": "indicator", "subject": "policy-rate",
        "material": "", "grade": "", "form": "", "unit": "percent", "instrument": "policy",
    }
    keys = dict(zip(SERIES, (capacity, fuel, fuel, rate)))
    refs = {source: {"source": source, "revision": "r1"} for source in SERIES}
    evidence = [{"kind": "evidence", "expectedRef": refs[source], "expectedKey": keys[source]}
                for source in SERIES if source != "fuel/alternate" or second_quote]
    allocation = {"kind": "allocate", "allocation": {
        "resource": {"scope": SCOPE, "constraintId": "harbor-a/shared-cargo-space", "bucket": "20"},
        "source": refs["harbor/capacity"], "signal": capacity, "quantity": "7", "mode": "sea",
    }}
    costs = [{"kind": "cost", "line": {
        "source": refs[source], "signal": fuel, "atTime": "20", "currency": "USD",
        "components": ["harbor-a/bucket-20/jet-fuel-delivery"], "minorUnits": VALUES[source],
    }} for source in ("fuel/primary", "fuel/alternate") if source == "fuel/primary" or second_quote]
    return {
        "schema": "biz-kit/economic-planning/request-v1", "snapshot": snapshot,
        "model": "harbor-scenario-v1", "scenario": "synthetic sea baseline", "seed": "17",
        "horizonStart": "20", "horizonEnd": "23", "currency": "USD",
        "actions": evidence + [allocation] + costs + [{"kind": "publish", "claim": "scenario"}],
    }


class AdmissionTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.path = Path(temp.name) / "harbor.sqlite"
        self.store = AdmissionStore(self.path, KEYS)
        self.batch = [observation(source) for source in SERIES]

    def install(self, epoch=1, *, batch=None, grants=GRANTS, issued="11"):
        return self.store.install(epoch, issued, self.batch if batch is None else batch, grants)

    def test_reopen_and_replay_exact_certificate(self):
        name = self.install()
        raw = encode(request(name))
        reopened = AdmissionStore(self.path, KEYS)
        result = reopened.plan(raw, MEMBER)
        self.assertEqual(result, self.store.plan(raw, MEMBER))
        self.assertEqual(hashlib.sha256(result).hexdigest(),
                         "c600031cf7e3b1c0ce5e86a5640c89c6f0048df59dd70301e343e56b74db220d")
        certificate = json.loads(result)["certificate"]
        self.assertEqual(certificate["manifest"]["scenario"], "synthetic sea baseline")
        self.assertEqual(certificate["claim"], "scenario")
        self.assertEqual(certificate["allocations"][0]["quantity"], "7")
        self.assertEqual(certificate["costs"][0]["minorUnits"], "300")
        for item, index, value in zip(certificate["evidence"], (0, 1, 3), ("10", "300", None),
                                      strict=True):
            self.assertEqual(item["ref"], {"source": SERIES[index], "revision": "r1"})
            self.assertEqual(item["quantity"], value)
            self.assertEqual(item["payloadDigest"], hashlib.sha256(self.batch[index][0]).hexdigest())
            self.assertEqual([item[k] for k in ("publishedAt", "receivedAt",
                                                 "effectiveFrom", "effectiveUntil")],
                             ["9", "10", "20", "23"])
            self.assertEqual(item["origin"], "synthetic")
        self.assertNotIn(b"-0.25", result)

    def test_payload_or_provider_substitution(self):
        raw, tag, received = self.batch[0]
        forged = raw.replace(b'"10"', b'"99"')
        for changed in [(forged, tag, received),
                        (raw, observation_mac(KEYS["seller"], raw), received),
                        observation(SERIES[0], provider="seller")]:
            with self.subTest(changed=changed), self.assertRaisesRegex(
                PlanningError, "provider authentication",
            ):
                self.install(batch=[changed, *self.batch[1:]])

    def test_failed_install_rolls_back_partial_revision_inserts(self):
        name = self.install()
        new = observation(SERIES[0], ref={"source": SERIES[0], "revision": "r2"})
        substituted = observation(SERIES[1], value="999")
        grants = [(MEMBER.principal, SCOPE, SERIES[0], "r2"), *GRANTS[1:]]
        with self.assertRaisesRegex(PlanningError, "already bound"):
            self.install(2, batch=[new, substituted, *self.batch[2:]], grants=grants)
        with sqlite3.connect(self.path) as db:
            self.assertEqual(db.execute("SELECT count(*) FROM revision").fetchone(), (4,))
            self.assertEqual(db.execute("SELECT count(*) FROM snapshot").fetchone(), (1,))
        self.store.plan(encode(request(name)), MEMBER)
        revised = observation(SERIES[0], value="12", ref={"source": SERIES[0], "revision": "r2"})
        new_name = self.install(2, batch=[revised, *self.batch[1:]], grants=grants)
        proposal = request(new_name)
        with self.assertRaises(SourceUnavailable):
            self.store.plan(encode(proposal), MEMBER)
        proposal["actions"][0]["expectedRef"]["revision"] = "r2"
        proposal["actions"][3]["allocation"]["source"]["revision"] = "r2"
        certificate = json.loads(self.store.plan(encode(proposal), MEMBER))["certificate"]
        self.assertEqual(certificate["evidence"][0]["quantity"], "12")
        self.assertEqual(certificate["evidence"][0]["ref"]["revision"], "r2")

    def test_grant_revocation_stale_epoch_and_separate_identity(self):
        first = self.install()
        with self.assertRaises(SourceUnavailable):
            self.store.plan(encode(request(first)), HostIdentity("other", SCOPE))
        with self.assertRaises(SourceUnavailable):
            self.store.plan(encode(request(first)), HostIdentity("analyst", "other-scope"))
        second = self.install(2, grants=[g for g in GRANTS if g[2] != "fuel/primary"])
        for name in (first, second):
            with self.subTest(name=name), self.assertRaises(SourceUnavailable):
                self.store.plan(encode(request(name)), MEMBER)
        with self.assertRaisesRegex(PlanningError, "stale"):
            self.install()
        with self.assertRaisesRegex(PlanningError, "inconsistent"):
            self.install(3, grants=[(*GRANTS[0][:-1], "r0")])

    def test_install_is_serialized_with_both_authorization_checks(self):
        name = self.install()
        from . import reducer

        replay = reducer.replay_final

        def race(bundle):
            with sqlite3.connect(self.path, timeout=0) as contender:
                with self.assertRaisesRegex(sqlite3.OperationalError, "locked"):
                    contender.execute("BEGIN IMMEDIATE")
            return replay(bundle)

        with patch.object(reducer, "replay_final", side_effect=race) as checked:
            self.store.plan(encode(request(name)), MEMBER)
            checked.assert_called_once()
        self.install(2, grants=[])
        with self.assertRaises(SourceUnavailable):
            self.store.plan(encode(request(name)), MEMBER)

    def test_bad_time_bucket_duplicate_and_missing_series(self):
        for changed, message in [
            (observation(SERIES[0], publishedAt="11"), "inconsistent observation times"),
            (observation(SERIES[0], effectiveUntil="24"), "registered bucket"),
            ((self.batch[0][0], self.batch[0][1], "12"), "inconsistent observation times"),
        ]:
            with self.subTest(message=message), self.assertRaisesRegex(PlanningError, message):
                self.install(batch=[changed, *self.batch[1:]])
        with self.assertRaisesRegex(PlanningError, "duplicate observation"):
            self.install(batch=[*self.batch, self.batch[0]])
        with self.assertRaisesRegex(PlanningError, "incomplete observation"):
            self.install(batch=self.batch[:-1])

    def test_null_capacity_admits_evidence_and_denies_allocation(self):
        missing = observation(SERIES[0], value=None)
        name = self.install(batch=[missing, *self.batch[1:]])
        proposal = request(name)
        with self.assertRaises(TraceRejected):
            self.store.plan(encode(proposal), MEMBER)
        proposal["actions"] = [a for a in proposal["actions"] if a["kind"] != "allocate"]
        result = json.loads(self.store.plan(encode(proposal), MEMBER))
        self.assertIsNone(result["certificate"]["evidence"][0]["quantity"])

    def test_signed_fractional_and_numeric_literals_are_never_coerced(self):
        for value in ("-1", "+1", "1.5", "2.0", "1e2", "-0", 1, 1.5, True):
            with self.subTest(value=value), self.assertRaises(wire.SchemaError):
                self.install(batch=[self.batch[0], observation(SERIES[1], value=value), *self.batch[2:]])

    def test_two_quotes_share_one_economic_effect_and_cannot_rename_it(self):
        name = self.install()
        proposal = request(name, second_quote=True)
        with self.assertRaises(TraceRejected):
            self.store.plan(encode(proposal), MEMBER)
        proposal["actions"][-2]["line"]["components"] = ["renamed-effect"]
        with self.assertRaisesRegex(PlanningError, "host quote binding"):
            self.store.plan(encode(proposal), MEMBER)

    def test_wire_and_scenario_only_guards(self):
        name = self.install()
        proposal = request(name)
        proposal["actions"][-1]["claim"] = "forecast"
        with self.assertRaisesRegex(PlanningError, "scenario claims only"):
            self.store.plan(encode(proposal), MEMBER)
        proposal["priorState"] = {}
        with self.assertRaises(wire.SchemaError):
            self.store.plan(encode(proposal), MEMBER)


if __name__ == "__main__":
    unittest.main()
