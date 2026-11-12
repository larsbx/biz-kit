"""Independent adversarial checks of the public offline planning boundary.

Fixtures are written in the declared wire format and encoded with Python's JSON
library, not the candidate's encoder. Successful cases assert complete expected
certificates; malformed or unauthorized requests must release no prefix state.
"""
from __future__ import annotations

from copy import deepcopy
from dataclasses import FrozenInstanceError
import hashlib
import json
import unittest
from unittest.mock import patch

from . import reducer, wire
from .boundary import (
    FrozenSnapshot, HostIdentity, PlanningBoundary, PlanningError,
    SourceUnavailable, TraceRejected,
)


def encode(value: object, *, ascii_only: bool = False) -> bytes:
    return json.dumps(value, ensure_ascii=ascii_only, separators=(",", ":")).encode("utf-8")


def fixtures() -> tuple[dict, dict]:
    physical = {
        "family": "dispatch", "measure": "physicalQuantity", "subject": "cargo-space",
        "material": "produce", "grade": "A", "form": "packed", "unit": "kg",
        "currency": "", "location": "transfer-yard", "instrument": "physical", "maturity": None,
    }
    monetary = {
        "family": "fuel", "measure": "moneyMinorUnits", "subject": "delivered-charge",
        "material": "jet-fuel", "grade": "Jet A-1", "form": "liquid", "unit": "minor-unit",
        "currency": "USD", "location": "transfer-yard", "instrument": "physical", "maturity": None,
    }
    capacity_ref = {"source": "capacity-provider", "revision": "cap-r1"}
    cost_ref = {"source": "fuel-provider", "revision": "quote-r1"}
    capacity = {
        "ref": capacity_ref, "key": physical, "scope": "business-a", "publishedAt": "9",
        "receivedAt": "10", "effectiveFrom": "20", "effectiveUntil": "23",
        "origin": "observed", "quantity": "10", "payloadDigest": "a" * 64,
    }
    charge = {
        "ref": cost_ref, "key": monetary, "scope": "business-a", "publishedAt": "9",
        "receivedAt": "10", "effectiveFrom": "20", "effectiveUntil": "23",
        "origin": "observed", "quantity": "300", "payloadDigest": "b" * 64,
    }
    resource_key = {"scope": "business-a", "constraintId": "shared-loading-space", "bucket": "20"}
    host = {
        "schema": "biz-kit/economic-planning/host-snapshot-v1", "scope": "business-a",
        "issuedAt": "10", "snapshot": "snapshot-r1", "models": ["academic-model-r1"],
        "operationalToken": "private-host-token", "sources": [capacity, charge],
        "costComponents": [{"source": cost_ref, "components": ["delivery/base", "delivery/fuel"]}],
        "resources": [{"key": resource_key, "value": {
            "source": capacity_ref, "signal": physical, "capacity": "10",
        }}],
    }
    request = {
        "schema": "biz-kit/economic-planning/request-v1", "snapshot": "snapshot-r1",
        "model": "academic-model-r1", "scenario": "baseline", "seed": "17",
        "horizonStart": "20", "horizonEnd": "23", "currency": "USD",
        "actions": [
            {"kind": "evidence", "expectedRef": capacity_ref, "expectedKey": physical},
            {"kind": "evidence", "expectedRef": cost_ref, "expectedKey": monetary},
            {"kind": "allocate", "allocation": {
                "resource": resource_key, "source": capacity_ref, "signal": physical,
                "quantity": "7", "mode": "sea",
            }},
            {"kind": "cost", "line": {
                "source": cost_ref, "signal": monetary, "atTime": "20",
                "components": ["delivery/base", "delivery/fuel"], "currency": "USD", "minorUnits": "300",
            }},
            {"kind": "publish", "claim": "forecast"},
        ],
    }
    # Break every alias, including repeated references within each document, as
    # independently decoded JSON objects do. deepcopy preserves internal aliases.
    return json.loads(encode(host)), json.loads(encode(request))


def expected_certificate(host: dict, request: dict) -> dict:
    """Expected successful fixture value, without executing candidate transitions."""
    manifest = {key: request[key] for key in (
        "snapshot", "model", "scenario", "seed", "horizonStart", "horizonEnd", "currency",
    )}
    manifest.update(scope=host["scope"], issuedAt=host["issuedAt"])
    references = [a["expectedRef"] for a in request["actions"] if a["kind"] == "evidence"]
    return deepcopy({
        "manifest": manifest, "claim": request["actions"][-1]["claim"],
        "evidence": [next(e for e in host["sources"] if e["ref"] == ref) for ref in references],
        "allocations": [a["allocation"] for a in request["actions"] if a["kind"] == "allocate"],
        "costs": [a["line"] for a in request["actions"] if a["kind"] == "cost"],
    })


class BoundaryAdversarialTests(unittest.TestCase):
    def setUp(self):
        self.host, self.request = fixtures()
        self.identity = HostIdentity("authenticated-member", "business-a")

    def boundary(self, host=None, authorize=None):
        return PlanningBoundary(
            FrozenSnapshot(encode(self.host if host is None else host)),
            (lambda identity, snapshot, ref: True) if authorize is None else authorize,
        )

    def plan(self, request=None, host=None, authorize=None):
        return json.loads(self.boundary(host, authorize).plan(
            encode(self.request if request is None else request), self.identity,
        ))

    def assert_rejected(self, index: int, request=None, host=None):
        with self.assertRaises(TraceRejected) as captured:
            self.plan(request=request, host=host)
        error = captured.exception
        self.assertEqual(error.index, index)
        self.assertFalse(hasattr(error, "states"))
        self.assertNotIn("private-host-token", str(error))
        self.assertNotIn("payloadDigest", str(error))

    def test_complete_successful_certificate_and_private_token_exclusion(self):
        output = self.boundary().plan(encode(self.request), self.identity)
        result = json.loads(output)
        self.assertEqual(set(result), {"schema", "certificate", "requestDigest", "snapshotDigest", "replayDigest"})
        self.assertEqual(result["schema"], "biz-kit/economic-planning/result-v1")
        self.assertEqual(result["certificate"], expected_certificate(self.host, self.request))
        self.assertNotIn(b"private-host-token", output)
        self.assertNotIn(b"operationalToken", output)
        self.assertNotIn(b'"states"', output)

    def test_authority_calls_bind_identity_snapshot_and_exact_reference_twice(self):
        calls = []

        def authorize(identity, snapshot, ref):
            calls.append((identity, snapshot, deepcopy(ref)))
            return True

        self.plan(authorize=authorize)
        expected = [(self.identity, "snapshot-r1", e["ref"]) for e in self.host["sources"]]
        self.assertEqual(calls, expected + expected)

    def test_only_exact_boolean_true_authorizes(self):
        for verdict in (False, None, 0, 1, "true", [True], {"allowed": True}, object()):
            with self.subTest(verdict=repr(verdict)):
                with self.assertRaisesRegex(SourceUnavailable, "^requested source is unavailable$"):
                    self.plan(authorize=lambda *args: verdict)

    def test_authorizer_exception_denies_without_leaking_its_message(self):
        def authorize(*args):
            raise RuntimeError("credential=private-provider-secret")

        with self.assertRaises(SourceUnavailable) as captured:
            self.plan(authorize=authorize)
        self.assertEqual(str(captured.exception), "requested source is unavailable")

    def test_absent_and_denied_sources_have_same_public_error(self):
        with self.assertRaises(SourceUnavailable) as denied:
            self.plan(authorize=lambda *args: False)
        self.request["actions"][0]["expectedRef"]["source"] = "not-present"
        with self.assertRaises(SourceUnavailable) as absent:
            self.plan()
        self.assertEqual(str(denied.exception), str(absent.exception))

    def test_foreign_host_identity_is_denied_before_source_callbacks(self):
        calls = []
        boundary = self.boundary(authorize=lambda *args: calls.append(args) or True)
        with self.assertRaises(SourceUnavailable):
            boundary.plan(encode(self.request), HostIdentity("authenticated-member", "business-b"))
        self.assertEqual(calls, [])
        with self.assertRaises(TypeError):
            boundary.plan(encode(self.request), {"principal": "forged", "scope": "business-a"})

    def test_revocation_at_release_returns_no_certificate(self):
        calls = {}

        def authorize(identity, snapshot, ref):
            key = (ref["source"], ref["revision"])
            calls[key] = calls.get(key, 0) + 1
            return calls[key] == 1

        with self.assertRaises(SourceUnavailable):
            self.plan(authorize=authorize)
        self.assertTrue(any(count == 2 for count in calls.values()))

    def test_authorizer_cannot_mutate_the_reference_used_for_replay(self):
        seen = []

        def authorize(identity, snapshot, ref):
            seen.append(deepcopy(ref))
            ref.clear()
            ref.update(source="substituted", revision="other")
            return True

        self.assertEqual(self.plan(authorize=authorize)["certificate"], expected_certificate(self.host, self.request))
        expected = [e["ref"] for e in self.host["sources"]]
        self.assertEqual(seen, expected + expected)

    def test_snapshot_and_prior_results_do_not_share_mutable_graphs(self):
        raw_host = encode(self.host)
        frozen = FrozenSnapshot(raw_host)
        boundary = PlanningBoundary(frozen, lambda *args: True)
        request = encode(self.request)
        expected = expected_certificate(self.host, self.request)
        self.host["sources"][0]["quantity"] = "100000"
        self.host["resources"][0]["value"]["capacity"] = "100000"
        self.host["sources"][1]["key"]["currency"] = "EUR"
        first = boundary.plan(request, self.identity)
        decoded = json.loads(first)
        decoded["certificate"]["evidence"][0]["quantity"] = "0"
        decoded["certificate"]["allocations"].clear()
        self.assertEqual(json.loads(boundary.plan(request, self.identity))["certificate"], expected)
        self.assertEqual(boundary.plan(request, self.identity), first)
        with self.assertRaises(FrozenInstanceError):
            frozen._canonical = b"{}"
        with self.assertRaises(FrozenInstanceError):
            self.identity.scope = "business-b"

    def test_materialized_host_values_are_independent_copies(self):
        frozen = FrozenSnapshot(encode(self.host))
        before = frozen.digest
        copy = frozen._materialize()
        copy["sources"][0]["ref"]["revision"] = "tampered"
        copy["resources"].clear()
        self.assertEqual(frozen.digest, before)
        self.assertEqual(frozen._materialize()["sources"][0]["ref"], self.host["sources"][0]["ref"])
        self.assertEqual(len(frozen._materialize()["resources"]), 1)

    def test_inflight_snapshot_replacement_cannot_mix_context_and_commitment(self):
        original = FrozenSnapshot(encode(self.host))
        replacement_host = deepcopy(self.host)
        replacement_host.update(snapshot="snapshot-r2", issuedAt="11", operationalToken="replacement-host-token")
        replacement_host["sources"][0]["quantity"] = "12"
        replacement_host["resources"][0]["value"]["capacity"] = "12"
        replacement = FrozenSnapshot(encode(replacement_host))
        calls = []
        swapped = False

        def authorize(identity, snapshot, ref):
            nonlocal swapped
            calls.append(snapshot)
            if not swapped:
                boundary._snapshot = replacement
                swapped = True
            return True

        boundary = PlanningBoundary(original, authorize)
        before = json.loads(boundary.plan(encode(self.request), self.identity))
        self.assertEqual(before["certificate"], expected_certificate(self.host, self.request))
        self.assertEqual(before["snapshotDigest"], original.digest)
        self.assertEqual(calls, ["snapshot-r1"] * 4)
        later_request = deepcopy(self.request)
        later_request["snapshot"] = "snapshot-r2"
        after = json.loads(boundary.plan(encode(later_request), self.identity))
        self.assertEqual(after["certificate"], expected_certificate(replacement_host, later_request))
        self.assertEqual(after["snapshotDigest"], replacement.digest)
        self.assertNotEqual(before["snapshotDigest"], after["snapshotDigest"])
        self.assertEqual(calls, ["snapshot-r1"] * 4 + ["snapshot-r2"] * 4)

    def test_prepared_bundle_byte_limit_is_checked_before_reducer_execution(self):
        # Construct expected wire bytes independently of the boundary's encoder
        # and reducer, including host-supplied evidence in each prepared action.
        actions = []
        for action in self.request["actions"]:
            if action["kind"] == "evidence":
                record = next(e for e in self.host["sources"] if e["ref"] == action["expectedRef"])
                actions.append({"kind": "evidence", "request": {
                    "expectedRef": action["expectedRef"], "expectedKey": action["expectedKey"], "evidence": record,
                }})
            else:
                actions.append(action)
        bundle = {
            "manifest": expected_certificate(self.host, self.request)["manifest"],
            "sources": self.host["sources"], "readable": [e["ref"] for e in self.host["sources"]],
            "resources": self.host["resources"], "operationalToken": self.host["operationalToken"], "actions": actions,
        }
        replay_bytes = json.dumps(bundle, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
        digest = hashlib.sha256(b"biz-kit/economic-planning/replay-v1\x00" + replay_bytes).hexdigest()
        with patch.object(wire, "BUNDLE_BYTES", len(replay_bytes)):
            self.assertEqual(self.plan()["replayDigest"], digest)
        with patch.object(wire, "BUNDLE_BYTES", len(replay_bytes) - 1), patch.object(reducer, "replay_final") as replay:
            with self.assertRaisesRegex(PlanningError, "^prepared replay exceeds its byte limit$"):
                self.plan()
            replay.assert_not_called()

    def test_forged_authority_state_and_host_fields_are_rejected(self):
        forbidden = {
            "scope": "business-b", "issuedAt": "0", "canRead": True, "readable": [],
            "principal": "admin", "identity": {"principal": "admin", "scope": "business-a"},
            "operationalToken": "forged", "sources": self.host["sources"],
            "resources": self.host["resources"], "state": {}, "certificate": {},
            "costComponents": self.host["costComponents"],
        }
        for key, value in forbidden.items():
            with self.subTest(field=key):
                request = deepcopy(self.request)
                request[key] = value
                with self.assertRaises(wire.SchemaError):
                    self.plan(request=request)
        request = deepcopy(self.request)
        request["actions"][0]["evidence"] = deepcopy(self.host["sources"][0])
        with self.assertRaises(wire.SchemaError):
            self.plan(request=request)
        request = deepcopy(self.request)
        request["actions"][2]["allocation"]["canRead"] = True
        with self.assertRaises(wire.SchemaError):
            self.plan(request=request)

    def test_unknown_and_missing_fields_rejected_at_nested_boundaries(self):
        paths = [(), ("actions", 0), ("actions", 0, "expectedRef"),
                 ("actions", 0, "expectedKey"), ("actions", 2, "allocation"),
                 ("actions", 2, "allocation", "resource"), ("actions", 3, "line")]
        for path in paths:
            for add in (True, False):
                with self.subTest(path=path, add=add):
                    request = deepcopy(self.request)
                    node = request
                    for part in path:
                        node = node[part]
                    if add:
                        node["unexpected"] = "value"
                    else:
                        del node[next(iter(node))]
                    with self.assertRaises(wire.SchemaError):
                        self.plan(request=request)

    def test_duplicate_decoded_json_keys_are_rejected_before_authority(self):
        raw = encode(self.request)
        attacks = [
            b'{"model":"evil",' + raw[1:],
            b'{"\\u006dodel":"evil",' + raw[1:],
            raw.replace(b'"quantity":"7"', b'"quantity":"7","\\u0071uantity":"6"'),
            raw.replace(b'"source":"capacity-provider"', b'"source":"capacity-provider","source":"other"', 1),
        ]
        for attack in attacks:
            with self.subTest(attack=attack[:70]):
                calls = []
                with self.assertRaises(wire.SchemaError):
                    self.boundary(authorize=lambda *args: calls.append(args) or True).plan(attack, self.identity)
                self.assertEqual(calls, [])
        raw_host = encode(self.host)
        with self.assertRaises(wire.SchemaError):
            FrozenSnapshot(b'{"scope":"business-a",' + raw_host[1:])

    def test_malformed_json_utf8_surrogates_and_controls_are_rejected(self):
        raw = encode(self.request)
        attacks = [b"", b"\xff" + raw, b"\xef\xbb\xbf" + raw, raw + b"{}", raw[:-1]]
        for invalid in ("\ud800", "\udfff", "line\x00break", "line\x1fbreak", "delete\x7f"):
            request = deepcopy(self.request)
            request["scenario"] = invalid
            attacks.append(encode(request, ascii_only=True))
        for attack in attacks:
            with self.subTest(attack=attack[:40]):
                with self.assertRaises(wire.SchemaError):
                    self.boundary().plan(attack, self.identity)
        with self.assertRaises(wire.SchemaError):
            self.boundary().plan(raw.decode("utf-8"), self.identity)
        with self.assertRaises(wire.SchemaError):
            FrozenSnapshot(bytearray(encode(self.host)))

    def test_all_numeric_literals_and_noncanonical_naturals_are_refused(self):
        invalid = [True, False, None, 0, 1, -1, 1.0, 1e3, float("nan"), float("inf"),
                   float("-inf"), "", "+1", "-0", "-1", "00", "01", "1.0", "1e3",
                   " 1", "1 ", "\u0661", "9223372036854775808", "99999999999999999999"]
        for value in invalid:
            with self.subTest(value=repr(value)):
                request = deepcopy(self.request)
                request["seed"] = value
                with self.assertRaises(wire.SchemaError):
                    self.plan(request=request)

    def test_exact_large_quantities_and_sum_do_not_round_or_wrap(self):
        for amount in (2**53 + 1, 2**63 - 1):
            with self.subTest(amount=amount):
                host, request = fixtures()
                host["sources"][0]["quantity"] = str(amount)
                host["resources"][0]["value"]["capacity"] = str(amount)
                request["actions"][2]["allocation"]["quantity"] = str(amount)
                request["seed"] = str(amount)
                certificate = self.plan(host=host, request=request)["certificate"]
                self.assertEqual(certificate["allocations"][0]["quantity"], str(amount))
                self.assertEqual(certificate["manifest"]["seed"], str(amount))
                extra = deepcopy(request["actions"][2])
                extra["allocation"].update(quantity="1", mode="air")
                request["actions"].insert(3, extra)
                self.assert_rejected(3, host=host, request=request)

    def test_null_and_zero_are_distinct_unavailable_capacity_values(self):
        for capacity in (None, "0"):
            with self.subTest(capacity=capacity):
                host = deepcopy(self.host)
                host["sources"][0]["quantity"] = capacity
                host["resources"][0]["value"]["capacity"] = capacity
                self.assertEqual(wire.decode_snapshot(encode(host))["sources"][0]["quantity"],
                                 None if capacity is None else 0)
                self.assert_rejected(2, host=host)
        for section in ("sources", "resources"):
            host = deepcopy(self.host)
            if section == "sources":
                del host[section][0]["quantity"]
            else:
                del host[section][0]["value"]["capacity"]
            with self.assertRaises(wire.SchemaError):
                FrozenSnapshot(encode(host))

    def test_json_string_byte_and_document_size_bounds(self):
        for value in ("a" * 512, "\U0001f642" * 128):
            request = deepcopy(self.request)
            request["scenario"] = value
            self.assertEqual(self.plan(request=request)["certificate"]["manifest"]["scenario"], value)
        for value in ("a" * 513, "\U0001f642" * 129):
            request = deepcopy(self.request)
            request["scenario"] = value
            with self.assertRaises(wire.SchemaError):
                self.plan(request=request)
        raw = encode(self.request)
        exact = raw + b" " * (256 * 1024 - len(raw))
        self.assertEqual(json.loads(self.boundary().plan(exact, self.identity))["certificate"],
                         expected_certificate(self.host, self.request))
        with self.assertRaises(wire.SchemaError):
            self.boundary().plan(exact + b" ", self.identity)
        host_raw = encode(self.host)
        FrozenSnapshot(host_raw + b" " * (1024 * 1024 - len(host_raw)))
        with self.assertRaises(wire.SchemaError):
            FrozenSnapshot(host_raw + b" " * (1024 * 1024 + 1 - len(host_raw)))

    def test_nesting_and_node_limits_ignore_brackets_inside_strings(self):
        self.assertEqual(wire.loads(b'"' + b"[" * 512 + b'"'), "[" * 512)
        wire.loads(b"[" * 24 + b"null" + b"]" * 24)
        with self.assertRaises(wire.SchemaError):
            wire.loads(b"[" * 25 + b"null" + b"]" * 25)
        wire.loads(b"[" + b",".join([b"null"] * 49_999) + b"]", max_bytes=1024 * 1024)
        with self.assertRaises(wire.SchemaError):
            wire.loads(b"[" + b",".join([b"null"] * 50_000) + b"]", max_bytes=1024 * 1024)
        self.request["scenario"] = 'escaped \\" braces ] [ { }'
        self.assertEqual(self.plan()["certificate"]["manifest"]["scenario"], self.request["scenario"])

    def test_bounded_collections_reject_one_above_each_limit(self):
        request = deepcopy(self.request)
        request["actions"] = [deepcopy(request["actions"][0]) for _ in range(255)] + [request["actions"][-1]]
        self.assertEqual(len(wire.decode_request(encode(request))["actions"]), 256)
        request["actions"].insert(0, deepcopy(request["actions"][0]))
        with self.assertRaises(wire.SchemaError):
            wire.decode_request(encode(request))
        host = deepcopy(self.host)
        host["resources"] = []
        host["sources"] = []
        host["costComponents"] = []
        for i in range(128):
            source = deepcopy(self.host["sources"][0])
            source["ref"]["source"] = f"provider-{i}"
            host["sources"].append(source)
        FrozenSnapshot(encode(host))
        source = deepcopy(host["sources"][0])
        source["ref"]["source"] = "provider-128"
        host["sources"].append(source)
        with self.assertRaises(wire.SchemaError):
            FrozenSnapshot(encode(host))
        host = deepcopy(self.host)
        host["resources"] = []
        for i in range(256):
            resource = deepcopy(self.host["resources"][0])
            resource["key"]["constraintId"] = f"constraint-{i}"
            host["resources"].append(resource)
        FrozenSnapshot(encode(host))
        resource = deepcopy(host["resources"][0])
        resource["key"]["constraintId"] = "constraint-256"
        host["resources"].append(resource)
        with self.assertRaises(wire.SchemaError):
            FrozenSnapshot(encode(host))
        request = deepcopy(self.request)
        request["actions"][3]["line"]["components"] = [f"effect-{i}" for i in range(64)]
        host = deepcopy(self.host)
        host["costComponents"][0]["components"] = deepcopy(request["actions"][3]["line"]["components"])
        self.plan(request=request, host=host)
        request["actions"][3]["line"]["components"].append("effect-64")
        with self.assertRaises(wire.SchemaError):
            self.plan(request=request)

    def test_duplicate_source_and_resource_identities_never_choose_a_winner(self):
        for section in ("sources", "resources"):
            for conflict in (False, True):
                with self.subTest(section=section, conflict=conflict):
                    host = deepcopy(self.host)
                    duplicate = deepcopy(host[section][0])
                    if conflict:
                        if section == "sources":
                            duplicate["payloadDigest"] = "c" * 64
                        else:
                            duplicate["value"]["capacity"] = "11"
                    host[section].append(duplicate)
                    with self.assertRaises(wire.SchemaError):
                        FrozenSnapshot(encode(host))

    def test_structured_identities_do_not_collide_or_normalize_unicode(self):
        for refs in (
            ({"source": "a|b", "revision": "c"}, {"source": "a", "revision": "b|c"}),
            ({"source": "caf\u00e9", "revision": "v1"}, {"source": "cafe\u0301", "revision": "v1"}),
        ):
            with self.subTest(refs=refs):
                host, request = fixtures()
                host["sources"][0]["ref"], host["sources"][1]["ref"] = deepcopy(refs)
                host["resources"][0]["value"]["source"] = deepcopy(refs[0])
                host["costComponents"][0]["source"] = deepcopy(refs[1])
                request["actions"][0]["expectedRef"] = deepcopy(refs[0])
                request["actions"][1]["expectedRef"] = deepcopy(refs[1])
                request["actions"][2]["allocation"]["source"] = deepcopy(refs[0])
                request["actions"][3]["line"]["source"] = deepcopy(refs[1])
                self.assertEqual(self.plan(host=host, request=request)["certificate"], expected_certificate(host, request))

    def test_catalog_must_bind_exact_source_quantity_signal_and_scope(self):
        mutations = [
            lambda h: h["sources"][0].update(scope="business-b"),
            lambda h: h["resources"][0]["key"].update(scope="business-b"),
            lambda h: h["resources"][0]["value"].update(capacity="11"),
            lambda h: h["resources"][0]["value"]["source"].update(revision="cap-r2"),
            lambda h: h["resources"][0]["value"]["signal"].update(grade="B"),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(mutation=index):
                host = deepcopy(self.host)
                mutate(host)
                with self.assertRaises(wire.SchemaError):
                    FrozenSnapshot(encode(host))
        host = deepcopy(self.host)
        host["resources"][0]["value"] = {
            "source": deepcopy(host["sources"][1]["ref"]),
            "signal": deepcopy(host["sources"][1]["key"]), "capacity": "300",
        }
        with self.assertRaises(wire.SchemaError):
            FrozenSnapshot(encode(host))

    def test_digest_units_currency_and_required_optional_fields_are_strict(self):
        for digest in ("", "a" * 63, "a" * 65, "A" * 64, "g" * 64):
            host = deepcopy(self.host)
            host["sources"][0]["payloadDigest"] = digest
            with self.assertRaises(wire.SchemaError):
                FrozenSnapshot(encode(host))
        for unit in ("USD", "cent", "minor_units", ""):
            host = deepcopy(self.host)
            host["sources"][1]["key"]["unit"] = unit
            with self.assertRaises(wire.SchemaError):
                FrozenSnapshot(encode(host))
        for currency in ("", "usd", "US", "USDD", " USD", "USD "):
            request = deepcopy(self.request)
            request["currency"] = currency
            with self.assertRaises(wire.SchemaError):
                self.plan(request=request)
        request = deepcopy(self.request)
        del request["actions"][0]["expectedKey"]["maturity"]
        with self.assertRaises(wire.SchemaError):
            self.plan(request=request)

    def test_every_signal_identity_field_remains_bound_to_the_host_record(self):
        replacements = {
            "family": "geopolitics", "measure": "indicator", "subject": "other",
            "material": "other", "grade": "B", "form": "bulk", "unit": "tonne",
            "currency": "EUR", "location": "another-yard", "instrument": "futures", "maturity": "30",
        }
        for field, value in replacements.items():
            with self.subTest(field=field):
                request = deepcopy(self.request)
                request["actions"][0]["expectedKey"][field] = value
                self.assert_rejected(0, request=request)
        request = deepcopy(self.request)
        request["actions"][0]["expectedRef"]["revision"] = "cap-r2"
        with self.assertRaises(SourceUnavailable):
            self.plan(request=request)

    def test_unknown_enum_values_are_rejected_without_case_folding(self):
        mutations = [
            lambda r: r["actions"][0]["expectedKey"].update(family="PreciousMetal"),
            lambda r: r["actions"][0]["expectedKey"].update(measure="physical"),
            lambda r: r["actions"][0]["expectedKey"].update(instrument="option"),
            lambda r: r["actions"][2]["allocation"].update(mode="AIR"),
            lambda r: r["actions"][-1].update(claim="prediction"),
            lambda r: r["actions"][0].update(kind="execute"),
        ]
        for mutate in mutations:
            request = deepcopy(self.request)
            mutate(request)
            with self.assertRaises(wire.SchemaError):
                self.plan(request=request)
        host = deepcopy(self.host)
        host["sources"][0]["origin"] = "official"
        with self.assertRaises(wire.SchemaError):
            FrozenSnapshot(encode(host))

    def test_known_at_issuance_includes_equality_but_excludes_later_information(self):
        for field in ("publishedAt", "receivedAt"):
            host = deepcopy(self.host)
            host["sources"][0][field] = "10"
            self.plan(host=host)
            host["sources"][0][field] = "11"
            self.assert_rejected(0, host=host)

    def test_future_effective_evidence_only_supports_capacity_when_effective(self):
        self.host["sources"][0]["effectiveFrom"] = "21"
        self.assert_rejected(2)
        self.host["resources"][0]["key"]["bucket"] = "21"
        self.request["actions"][2]["allocation"]["resource"]["bucket"] = "21"
        self.assertEqual(self.plan()["certificate"]["allocations"][0]["resource"]["bucket"], "21")

    def test_capacity_effect_and_horizon_intervals_are_half_open(self):
        for bucket, effective_start, effective_end in (("19", "19", "24"), ("23", "19", "24"), ("20", "19", "20")):
            host, request = fixtures()
            host["sources"][0].update(effectiveFrom=effective_start, effectiveUntil=effective_end)
            host["resources"][0]["key"]["bucket"] = bucket
            request["actions"][2]["allocation"]["resource"]["bucket"] = bucket
            self.assert_rejected(2, host=host, request=request)
        self.plan()  # Bucket equals both effective and horizon start.
        for start, end in (("20", "20"), ("21", "20")):
            host = deepcopy(self.host)
            host["sources"][0].update(effectiveFrom=start, effectiveUntil=end)
            with self.assertRaises(wire.SchemaError):
                FrozenSnapshot(encode(host))

    def test_cost_effect_and_horizon_intervals_are_half_open(self):
        for at_time, effective_start, effective_end in (("19", "19", "24"), ("23", "19", "24"), ("20", "19", "20")):
            host, request = fixtures()
            host["sources"][1].update(effectiveFrom=effective_start, effectiveUntil=effective_end)
            request["actions"][3]["line"]["atTime"] = at_time
            self.assert_rejected(3, host=host, request=request)
        self.plan()

    def test_shared_capacity_across_every_mode_and_zero_quantity(self):
        modes = ("road", "air", "sea", "rail", "inlandWater", "production", "storage")
        for mode in modes:
            with self.subTest(mode=mode):
                request = deepcopy(self.request)
                extra = deepcopy(request["actions"][2])
                extra["allocation"].update(quantity="3", mode=mode)
                request["actions"].insert(3, extra)
                self.assertEqual(len(self.plan(request=request)["certificate"]["allocations"]), 2)
                extra["allocation"]["quantity"] = "4"
                self.assert_rejected(3, request=request)
        self.request["actions"][2]["allocation"]["quantity"] = "0"
        self.assert_rejected(2)

    def test_foreign_or_unknown_nested_resource_does_not_change_authoritative_scope(self):
        for field, value in (("scope", "business-b"), ("constraintId", "invented-space")):
            request = deepcopy(self.request)
            request["actions"][2]["allocation"]["resource"][field] = value
            self.assert_rejected(2, request=request)

    def test_cost_amount_currency_components_and_quote_replay_are_enforced(self):
        for mutate in (
            lambda line: line.update(minorUnits="301"),
            lambda line: line.update(currency="EUR"),
        ):
            request = deepcopy(self.request)
            mutate(request["actions"][3]["line"])
            self.assert_rejected(3, request=request)
        request = deepcopy(self.request)
        replay = deepcopy(request["actions"][3])
        replay["line"]["components"] = ["new-name-for-the-same-quote"]
        request["actions"].insert(4, replay)
        with self.assertRaises(PlanningError):
            self.plan(request=request)
        replay["line"]["components"] = ["delivery/base", "delivery/fuel"]
        self.assert_rejected(4, request=request)
        for components in ([], ["delivery/fuel", "delivery/fuel"]):
            request = deepcopy(self.request)
            request["actions"][3]["line"]["components"] = components
            with self.assertRaises(PlanningError):
                self.plan(request=request)
        request = deepcopy(self.request)
        request["actions"][3]["line"]["components"] = [""]
        with self.assertRaises(wire.SchemaError):
            self.plan(request=request)

    def test_different_quote_cannot_repeat_a_covered_atomic_effect(self):
        source = deepcopy(self.host["sources"][1])
        source["ref"]["revision"] = "quote-r2"
        self.host["sources"].append(source)
        self.host["costComponents"].append({"source": deepcopy(source["ref"]), "components": ["delivery/fuel"]})
        self.request["actions"].insert(2, {
            "kind": "evidence", "expectedRef": deepcopy(source["ref"]), "expectedKey": deepcopy(source["key"]),
        })
        repeated = deepcopy(self.request["actions"][4])
        repeated["line"]["source"] = deepcopy(source["ref"])
        repeated["line"]["components"] = ["delivery/fuel"]
        self.request["actions"].insert(5, repeated)
        self.assert_rejected(5)
        repeated["line"]["components"] = ["independent-delivery/fuel"]
        with self.assertRaises(PlanningError):
            self.plan()
        self.host["costComponents"][-1]["components"] = ["independent-delivery/fuel"]
        self.assertEqual(len(self.plan()["certificate"]["costs"]), 2)

    def test_cost_bindings_are_host_owned_exact_and_required(self):
        for components in (["renamed/base", "renamed/fuel"], ["delivery/fuel", "delivery/base"], ["delivery/base"]):
            request = deepcopy(self.request)
            request["actions"][3]["line"]["components"] = components
            with self.assertRaises(PlanningError):
                self.plan(request=request)
        host = deepcopy(self.host)
        host["costComponents"] = []
        with self.assertRaises(PlanningError):
            self.plan(host=host)
        del host["costComponents"]
        with self.assertRaises(wire.SchemaError):
            FrozenSnapshot(encode(host))
        # An unadmitted private quote must fail replay identically regardless of
        # whether its component binding exists, instead of probing that catalog.
        request = deepcopy(self.request)
        del request["actions"][1]
        messages = []
        for bindings in (deepcopy(self.host["costComponents"]), []):
            host = deepcopy(self.host)
            host["costComponents"] = bindings
            with self.assertRaises(TraceRejected) as captured:
                self.plan(host=host, request=request)
            self.assertEqual(captured.exception.index, 2)
            messages.append(str(captured.exception))
        self.assertEqual(messages[0], messages[1])

    def test_cost_catalog_refuses_duplicate_unknown_physical_or_unquantified_sources(self):
        host = deepcopy(self.host)
        host["costComponents"].append(deepcopy(host["costComponents"][0]))
        with self.assertRaises(wire.SchemaError):
            FrozenSnapshot(encode(host))
        for reference in (self.host["sources"][0]["ref"], {"source": "missing", "revision": "v1"}):
            host = deepcopy(self.host)
            host["costComponents"][0]["source"] = deepcopy(reference)
            with self.assertRaises(wire.SchemaError):
                FrozenSnapshot(encode(host))
        host = deepcopy(self.host)
        host["sources"][1]["quantity"] = None
        with self.assertRaises(wire.SchemaError):
            FrozenSnapshot(encode(host))
        for components in ([], [""], ["delivery/fuel", "delivery/fuel"]):
            host = deepcopy(self.host)
            host["costComponents"][0]["components"] = components
            with self.assertRaises(wire.SchemaError):
                FrozenSnapshot(encode(host))

    def test_physical_quantity_cannot_be_submitted_as_a_monetary_charge(self):
        line = self.request["actions"][3]["line"]
        line.update(source=deepcopy(self.host["sources"][0]["ref"]),
                    signal=deepcopy(self.host["sources"][0]["key"]), minorUnits="10")
        with self.assertRaises(PlanningError):
            self.plan()

    def test_synthetic_and_hypothetical_sources_require_scenario_claims(self):
        for origin in ("synthetic", "hypothetical"):
            for source_index in (0, 1):
                with self.subTest(origin=origin, source=source_index):
                    host, request = fixtures()
                    host["sources"][source_index]["origin"] = origin
                    self.assert_rejected(4, host=host, request=request)
                    request["actions"][-1]["claim"] = "scenario"
                    self.assertEqual(self.plan(host=host, request=request)["certificate"]["claim"], "scenario")
        self.request["actions"][-1]["claim"] = "observed"
        self.assert_rejected(4)

    def test_nowcast_and_forecast_horizon_classification(self):
        for source in self.host["sources"]:
            source.update(effectiveFrom="9", effectiveUntil="12")
        self.host["resources"][0]["key"]["bucket"] = "10"
        self.request.update(horizonStart="9", horizonEnd="12")
        self.request["actions"][2]["allocation"]["resource"]["bucket"] = "10"
        self.request["actions"][3]["line"]["atTime"] = "10"
        self.request["actions"][-1]["claim"] = "nowcast"
        self.assertEqual(self.plan()["certificate"]["claim"], "nowcast")
        self.request["actions"][-1]["claim"] = "forecast"
        self.assert_rejected(4)
        self.request["actions"][-1]["claim"] = "nowcast"
        self.request["horizonEnd"] = "10"
        # Fail before publication: quantities at the excluded upper boundary.
        self.assert_rejected(2)

    def test_publication_must_be_single_final_action_and_have_evidence(self):
        for actions in (
            [], self.request["actions"][:-1],
            self.request["actions"] + [deepcopy(self.request["actions"][-1])],
            [deepcopy(self.request["actions"][-1])] + self.request["actions"][:-1],
        ):
            request = deepcopy(self.request)
            request["actions"] = deepcopy(actions)
            with self.assertRaises(wire.SchemaError):
                self.plan(request=request)
        self.request["actions"] = [{"kind": "publish", "claim": "forecast"}]
        self.assert_rejected(0)

    def test_unknown_snapshot_model_and_unapproved_horizons_are_refused(self):
        for field, value in (("snapshot", "snapshot-r2"), ("model", "unapproved-model")):
            request = deepcopy(self.request)
            request[field] = value
            with self.assertRaises(PlanningError):
                self.plan(request=request)
        for start, end in (("20", "20"), ("21", "20")):
            request = deepcopy(self.request)
            request.update(horizonStart=start, horizonEnd=end)
            with self.assertRaises(wire.SchemaError):
                self.plan(request=request)
        for models in ([], ["academic-model-r1", "academic-model-r1"]):
            host = deepcopy(self.host)
            host["models"] = models
            with self.assertRaises(wire.SchemaError):
                FrozenSnapshot(encode(host))

    def test_failure_reports_first_rejected_action_without_a_partial_publication(self):
        self.request["actions"][2]["allocation"]["quantity"] = "11"
        self.request["actions"][3]["line"]["minorUnits"] = "301"
        calls = []
        with self.assertRaises(TraceRejected) as captured:
            self.boundary(authorize=lambda *args: calls.append(args) or True).plan(encode(self.request), self.identity)
        self.assertEqual(captured.exception.index, 2)
        self.assertEqual(len(calls), 2)  # Source preparation occurred; release rechecks did not.
        self.assertEqual(set(vars(captured.exception)), {"index"})

    def test_commitments_bind_exact_requests_and_canonical_host_values(self):
        raw = encode(self.request)
        result = json.loads(self.boundary().plan(raw, self.identity))
        expected_request_digest = hashlib.sha256(b"biz-kit/economic-planning/request-v1\x00" + raw).hexdigest()
        canonical_host = json.dumps(self.host, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
        expected_snapshot_digest = hashlib.sha256(b"biz-kit/economic-planning/snapshot-v1\x00" + canonical_host).hexdigest()
        self.assertEqual(result["requestDigest"], expected_request_digest)
        self.assertEqual(result["snapshotDigest"], expected_snapshot_digest)
        for name in ("requestDigest", "snapshotDigest", "replayDigest"):
            self.assertRegex(result[name], r"^[0-9a-f]{64}$")
        reordered_host = dict(reversed(list(self.host.items())))
        self.assertEqual(FrozenSnapshot(encode(reordered_host)).digest, expected_snapshot_digest)
        whitespace = json.loads(self.boundary().plan(raw + b"\n ", self.identity))
        self.assertNotEqual(whitespace["requestDigest"], result["requestDigest"])
        self.assertEqual(whitespace["snapshotDigest"], result["snapshotDigest"])
        self.assertEqual(whitespace["replayDigest"], result["replayDigest"])
        self.assertEqual(whitespace["certificate"], result["certificate"])

    def test_later_snapshot_revision_cannot_rewrite_an_earlier_result(self):
        before = self.boundary().plan(encode(self.request), self.identity)
        later_host = deepcopy(self.host)
        later_host["snapshot"] = "snapshot-r2"
        later_host["issuedAt"] = "11"
        later = self.boundary(host=later_host)
        with self.assertRaises(PlanningError):
            later.plan(encode(self.request), self.identity)
        later_request = deepcopy(self.request)
        later_request["snapshot"] = "snapshot-r2"
        after = later.plan(encode(later_request), self.identity)
        self.assertEqual(json.loads(before)["certificate"]["manifest"]["issuedAt"], "10")
        self.assertEqual(json.loads(after)["certificate"]["manifest"]["issuedAt"], "11")
        self.assertNotEqual(json.loads(before)["snapshotDigest"], json.loads(after)["snapshotDigest"])


if __name__ == "__main__":
    unittest.main()
