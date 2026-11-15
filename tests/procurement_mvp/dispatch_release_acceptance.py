#!/usr/bin/env python3
"""Packaged procurement with a separate, actual Dispatch source process.

The coordinator uses verified loopback HTTPS. Dispatch uses its supported
private loopback HTTP transport and its authenticated courier Router. Each
peer invocation starts a fresh VM over committed disposable PostgreSQL rows.
Only the bundled procurement release owns the canonical business ledger.
This is not a packaged Dispatch, external IdP, graphical courier or live run.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import urllib.parse
import uuid

import release_acceptance as release

KIND = "procurement-packaged-dispatch-acceptance-v1"
EXECUTION = "packaged-procurement-source-dispatch-postgresql"
CHECKS = frozenset({
    "source_revision_bound", "separate_dispatch_without_appender", "authorized_assignment",
    "authenticated_pickup", "authenticated_dropoff", "wrong_pickup_code_denied",
    "wrong_dropoff_code_denied", "delivery_retry_inert", "worker_process_recovery",
    "packaged_host_custody_recovery", "original_order_and_quote_bound",
    "one_business_ledger", "no_payment_or_settlement", "restored_delivery_binding",
})
TRANSPORT = {
    "coordinator": "verified-loopback-https",
    "dispatch_to_procurement": "private-loopback-http",
    "courier": "authenticated-DispatchWeb.Router-in-source-vm",
}
PRE_CUSTODY_EVENTS = [
    "RoleKeyDeclared", "ProcurementOperatorGrantedV1",
    "ProcurementBusinessEnrolledV1", "ProcurementBusinessEnrolledV1", "ProcurementDispatchRouteV1",
] + ["ProcurementCommandAdmittedV1"] * 5 + ["ProcurementDispatchRequestedV1"]


def peer_environment(source: dict[str, str]) -> dict[str, str]:
    """Give the peer its operational database without host signing/session configuration."""
    release.require(source.get("PROCUREMENT_DISPATCH_ACCEPTANCE") == release.MODE,
                    "explicit disposable Dispatch opt-in required")
    url = source.get("DATABASE_URL", "")
    parsed = urllib.parse.urlsplit(url)
    release.require(parsed.scheme in {"ecto", "postgres", "postgresql"}
                    and parsed.hostname in {"127.0.0.1", "localhost", "::1"}
                    and parsed.port == 5432 and parsed.path == "/dispatch_test"
                    and bool(parsed.username) and bool(parsed.password)
                    and not parsed.query and not parsed.fragment,
                    "Dispatch peer requires the disposable loopback dispatch_test database on port 5432")
    release.require(not source.get("MIX_TEST_PARTITION"), "partitioned Dispatch database is not supported")
    # Tool/runtime configuration only. In particular, no EVENTSTORE_*, PG*,
    # host signing/governance/login keys or arbitrary integration credentials.
    allowed = {"PATH", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR",
               "MIX_HOME", "HEX_HOME", "MIX_ARCHIVES", "ERL_FLAGS", "ERL_AFLAGS"}
    env = {key: value for key, value in source.items() if key in allowed}
    env.update(DATABASE_URL=url, MIX_ENV="test", PROCUREMENT_ENABLED="false",
               BIZKIT_BUNDLED_TEST_LOCALE="true", RESTAURANT_DISPATCH_AUTOMATED="false",
               PROCUREMENT_DISPATCH_AUTOMATED="false", PROCUREMENT_DISPATCH_ACCEPTANCE=release.MODE)
    return env


def private_json(path: Path, value: dict) -> None:
    # Inputs (including handoff codes) stay in the temporary work directory,
    # never argv, stdout, the artifact directory or a durable receipt.
    with open(path, "w", opener=lambda name, flags: os.open(name, flags, 0o600)) as stream:
        json.dump(value, stream)
        stream.write("\n")


def uuid_value(value: object) -> bool:
    try:
        return isinstance(value, str) and str(uuid.UUID(value)) == value
    except (ValueError, AttributeError):
        return False


def validate_detail(detail: dict, trip: dict, quote: dict, *, phase: str,
                    operations: list[str], proof_digests: dict[str, str], revoked: bool = False) -> None:
    """Bind verified canonical events to the actual SQL assignment, not UUID-shaped fixtures."""
    rows = detail.get("requests")
    release.require(isinstance(rows, list) and len(rows) == 1, "expected exactly one canonical business order")
    row = rows[0]
    release.require((row.get("chapter_id"), row.get("cooperative_id"), row.get("order_id")) ==
                    ("acceptance-chapter", "acceptance-coop", trip["order_id"]), "canonical order scope changed")
    release.require(row.get("accepted_quote") == quote, "original complete accepted quote changed")
    steps = detail.get("steps")
    release.require(isinstance(steps, list) and [s.get("payload", {}).get("op") for s in steps] == operations,
                    "Dispatch steps were duplicated, omitted or reordered")
    expected_events = PRE_CUSTODY_EVENTS + ["ProcurementDispatchStepV1"] * len(operations)
    if revoked:
        expected_events += ["ProcurementOperatorGrantedV1"]
    release.require(detail.get("event_types") == expected_events,
                    "unexpected business, restaurant, payment or settlement event sequence")
    ledger = detail.get("ledger", {})
    release.require(ledger.get("global_seq") == len(expected_events)
                    and ledger.get("verified_event_count") == len(expected_events)
                    and bool(re.fullmatch(r"[0-9a-f]{64}", ledger.get("global_hash", "")))
                    and ledger.get("grant_active") is (not revoked)
                    and ledger.get("grant_version") == (2 if revoked else 1),
                    "inconsistent canonical head, verified history or grant state")
    for version, step in enumerate(steps):
        payload = step["payload"]
        release.require(step.get("chapter_id") == "acceptance-chapter"
                        and payload.get("cooperative_id") == "acceptance-coop"
                        and all(payload.get(key) == trip[key] for key in
                                ("order_id", "tenant_id", "load_id", "assignment_id"))
                        and payload.get("automated") is True
                        and payload.get("expected_version") == version,
                        "signed custody step is not bound to the actual assignment")
        release.require(step.get("signer_count") == 1 and step.get("signature_count") == 1
                        and step.get("signer_key_id") == "acceptance-dispatch"
                        and step.get("signer_role") == "procurement_dispatch",
                        "canonical Dispatch step has unexpected signing authority")
        if version:
            expected_digest = proof_digests[payload["op"]]
            expected_proof = str(uuid.UUID(bytes=bytes.fromhex(expected_digest)[:16]))
            release.require(payload.get("proof_id") == expected_proof
                            and payload.get("proof_digest") == expected_digest,
                            "signed custody proof is not bound to the presented handoff code")
    delivered = phase == "delivered"
    expected_order = {
        "id": trip["order_id"], "dispatch_phase": phase,
        "outcome_ref": "dispatch:" + steps[-1]["payload"]["proof_id"] if delivered else None,
        "phase": "fulfilled" if delivered else "accepted", "version": 7 if delivered else 6,
        "command_count": 6 if delivered else 5, "quote_revision": quote["revision"],
        "quote_total_minor": quote["total_minor"], "payment_evidence_count": 0,
    }
    release.require(ledger.get("requests") == [expected_order],
                    "canonical custody, original order, quote or payment boundary changed")

def validate_receipt(value: dict, revision: str, artifact_sha256: str) -> None:
    release.require(value.get("kind") == KIND and value.get("execution_kind") == EXECUTION,
                    "wrong combined acceptance kind")
    release.require(value.get("packaged_dispatch_worker") is False and value.get("live_delivery") is False,
                    "combined receipt overclaims packaging or live delivery")
    release.require(value.get("transport") == TRANSPORT, "combined receipt changes the transport boundary")
    release.validate_receipt({"kind": "procurement-packaged-acceptance-v1", "revision": value.get("revision"),
                              "artifact_sha256": value.get("artifact_sha256"), "trust": value.get("trust"),
                              "checks": value.get("host_checks")}, revision, artifact_sha256)
    checks = value.get("dispatch_checks")
    release.require(isinstance(checks, dict) and set(checks) == CHECKS
                    and all(result is True for result in checks.values()),
                    "missing, failed or skipped real Dispatch check")
    evidence = value.get("dispatch_evidence", {})
    release.require(evidence.get("source_revision") == revision, "source Dispatch revision mismatch")
    release.require(evidence.get("canonical_appender_in_dispatch") is False, "Dispatch owns another canonical appender")
    validate_detail(evidence["canonical_delivery"], evidence["assignment"], evidence["accepted_quote"],
                    phase="delivered", operations=["accept", "picked_up", "delivered"],
                    proof_digests=evidence["handoff_code_sha256"])
    restored = evidence.get("restored_delivery", {})
    validate_detail(restored, evidence["assignment"], evidence["accepted_quote"],
                    phase="delivered", operations=["accept", "picked_up", "delivered"],
                    proof_digests=evidence["handoff_code_sha256"], revoked=True)
    original = evidence["canonical_delivery"]
    release.require(restored["requests"] == original["requests"] and restored["steps"] == original["steps"]
                    and restored["ledger"] == value.get("restored_ledger")
                    and restored["ledger"]["global_hash"] != original["ledger"]["global_hash"],
                    "restoration evidence does not preserve the original delivery and revocation")


class DispatchDelivery:
    def __init__(self, harness: release.Harness, project: Path, revision: str, env: dict[str, str]):
        self.harness, self.project, self.revision, self.env = harness, project, revision, env
        self.checks: dict[str, bool] = {}
        self.observations: list[dict] = []
        self.state = harness.work / "dispatch-state.json"
        self.input = harness.work / "dispatch-input.json"
        self.seed = harness.work / "dispatch.seed"
        self.counter = 0
        self.identity: dict = {}
        self.trip: dict = {}
        self.quote: dict = {}
        self.proof_digests: dict = {}
        self.final: dict = {}
        self.restored: dict = {}
        self.config = {
            "state_file": str(self.state), "origin": "http://127.0.0.1:" + harness.env["PROCUREMENT_PORT"],
            "chapter": harness.env["PROCUREMENT_CHAPTER"], "cooperative": harness.env["PROCUREMENT_COOPERATIVE"],
            "key_id": "acceptance-dispatch", "seed_file": str(self.seed), "site": "Synthetic north dock",
            "pickup": "Synthetic supplier dock", "dropoff": "Synthetic north dock",
        }

    def peer(self, action: str, **fields) -> dict:
        private_json(self.input, dict(self.config, action=action, **fields))
        self.counter += 1
        log_path = self.harness.receipts / f"dispatch-{self.counter:02d}-{action}.log"
        fixture = Path(__file__).with_name("dispatch_peer.exs").resolve()
        with log_path.open("w") as log:
            child = subprocess.Popen(["mix", "run", "--no-start", "--no-compile", str(fixture), str(self.input)],
                                     cwd=self.project, env=self.env, stdout=log, stderr=subprocess.STDOUT,
                                     start_new_session=True)
            try:
                code = child.wait(timeout=120)
            except BaseException:
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGTERM)
                    try:
                        child.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait(timeout=5)
                raise
        release.require(code == 0, f"Dispatch {action} failed; see {log_path.name}")
        prefix = "PROCUREMENT_DISPATCH_PEER_JSON="
        records = [line[len(prefix):] for line in log_path.read_text().splitlines() if line.startswith(prefix)]
        release.require(len(records) == 1, "missing or ambiguous real Dispatch observation")
        result = json.loads(records[0])
        release.require(isinstance(result, dict) and result.get("no_canonical_appender") is True,
                        "peer started or failed to exclude a second canonical appender")
        self.observations.append(dict(result, action=action))
        return result

    def prepare(self):
        release.require((self.project / "mix.exs").is_file(), "Dispatch source project missing")
        marker = self.project.parents[1] / "SOURCE_REVISION"
        release.require(marker.read_text().strip() == self.revision, "staged Dispatch source revision mismatch")
        release.require(not list((self.harness.root / "lib").glob("dispatch-[0-9]*")),
                        "this gate expects a separate source Dispatch, not Dispatch inside procurement")
        self.checks["source_revision_bound"] = True
        self.seed.write_bytes(base64.b64encode(bytes.fromhex(self.harness.env["PROCUREMENT_FIXTURE_DISPATCH_SEED"])))
        self.seed.chmod(0o600)
        self.identity = self.peer("bootstrap")
        for key in ("tenant_id", "courier_id", "service_role_id", "courier_role_id"):
            release.require(uuid_value(self.identity.get(key)), "invalid actual Dispatch fixture identity: " + key)
        self.harness.env["PROCUREMENT_FIXTURE_DISPATCH_TENANT"] = self.identity["tenant_id"]

    def same_trip(self, result: dict, status: str):
        release.require(result.get("status") == status and result.get("load_count") == 1
                        and result.get("assignment_count") == 1, "duplicate or unexpected Dispatch assignment")
        release.require(result.get("tenant_id") == self.identity["tenant_id"]
                        and result.get("courier_id") == self.identity["courier_id"],
                        "assignment escaped the authorized tenant/courier")
        for key in ("load_id", "assignment_id"):
            release.require(uuid_value(result.get(key)), "Dispatch did not return a real assignment identity")
        expected_ref = ":".join(("procurement", self.config["chapter"], self.config["cooperative"], result["order_id"]))
        release.require(result.get("external_reference") == expected_ref, "Dispatch changed the exact order reference")
        if self.trip:
            release.require(all(result.get(key) == self.trip[key] for key in
                                ("tenant_id", "order_id", "load_id", "assignment_id", "courier_id", "external_reference")),
                            "retry or restart replaced the original assignment")

    def offline(self) -> dict:
        self.harness.stop()
        value = self.harness.fixture("inspect_dispatch")
        self.harness.start()
        return value

    def handoff(self, browser: release.Browser, path: str, quote: dict) -> str:
        order = path.rsplit("/", 1)[1]
        self.quote = quote
        # Inspect only after stopping the release, then restart the same host.
        # This captures the original accepted quote before any Dispatch step.
        original = self.offline()
        row = original["requests"]
        release.require(len(row) == 1 and row[0]["order_id"] == order
                        and row[0]["accepted_quote"] == quote and original["steps"] == []
                        and row[0]["dispatch_request"] is None and original["ledger"]["global_seq"] == 10,
                        "the original accepted quote does not match the coordinator's input")
        browser.submit(release.Forms(browser.page(path)).one("/dispatch", suffix=True), {})
        assigned = self.peer("worker", order_id=order)
        release.require(assigned.get("order_id") == order, "worker assigned a different order")
        self.same_trip(assigned, "ACTIVE")
        self.trip = {key: assigned[key] for key in
                     ("tenant_id", "order_id", "load_id", "assignment_id", "courier_id", "external_reference")}
        self.checks["authorized_assignment"] = True
        self.same_trip(self.peer("worker", order_id=order), "ACTIVE")
        page = browser.page(path)

        def code(label: str) -> str:
            found = re.findall(re.escape(label) + r" <code>([A-Za-z0-9_-]{22})</code>", page)
            release.require(len(found) == 1, "missing or ambiguous rendered custody code")
            return found[0]

        pickup, dropoff = code("Pickup code"), code("Drop-off code")
        release.require(pickup != dropoff, "pickup and drop-off codes are not distinct")
        self.proof_digests = {"picked_up": hashlib.sha256(pickup.encode()).hexdigest(),
                              "delivered": hashlib.sha256(dropoff.encode()).hexdigest()}

        def receipt(phase: str, handoff_token: str, expected: int, state: str = "ACTIVE"):
            observed = self.peer("receipt", order_id=order, phase=phase, handoff_token=handoff_token)
            release.require(observed.get("portal_status") == expected, "courier receipt returned the wrong status")
            self.same_trip(observed, state)

        receipt("picked_up", dropoff, 422)
        self.checks["wrong_pickup_code_denied"] = True
        receipt("picked_up", pickup, 200)
        self.checks["authenticated_pickup"] = True
        custody = self.offline()
        validate_detail(custody, self.trip, quote, phase="in_transit",
                        operations=["accept", "picked_up"], proof_digests=self.proof_digests)
        # Both participants have now stopped/restarted. A fresh peer must
        # reconcile committed SQL without a new trip or a new ledger event.
        self.same_trip(self.peer("worker", order_id=order), "ACTIVE")
        release.require(self.offline() == custody, "custody changed across host/worker process recovery")
        self.checks["worker_process_recovery"] = True
        self.checks["packaged_host_custody_recovery"] = True
        receipt("delivered", pickup, 422)
        self.checks["wrong_dropoff_code_denied"] = True
        receipt("delivered", dropoff, 200)
        self.checks["authenticated_dropoff"] = True
        self.same_trip(self.peer("worker", order_id=order), "COMPLETED")
        delivered = self.offline()
        release.require(delivered["event_types"] == original["event_types"] +
                        ["ProcurementDispatchRequestedV1"] + ["ProcurementDispatchStepV1"] * 3,
                        "handoff added an unexpected business event")
        validate_detail(delivered, self.trip, quote, phase="delivered",
                        operations=["accept", "picked_up", "delivered"], proof_digests=self.proof_digests)
        receipt("delivered", dropoff, 200, "COMPLETED")
        self.same_trip(self.peer("worker", order_id=order), "COMPLETED")
        release.require(self.offline() == delivered, "delivery retry changed authoritative history")
        self.checks["delivery_retry_inert"] = True
        self.final = delivered
        return "dispatch:" + delivered["steps"][-1]["payload"]["proof_id"]

    def verify(self, ledger: dict):
        detailed = self.harness.fixture("inspect_dispatch")
        release.require(detailed == self.final and detailed["ledger"] == ledger,
                        "coordinator retry changed the delivered order or binding")
        validate_detail(detailed, self.trip, self.quote, phase="delivered",
                        operations=["accept", "picked_up", "delivered"], proof_digests=self.proof_digests)
        self.checks.update(separate_dispatch_without_appender=True, original_order_and_quote_bound=True,
                           one_business_ledger=True, no_payment_or_settlement=True)

    def verify_restored(self, ledger: dict):
        restored = self.harness.fixture("inspect_dispatch")
        release.require(restored["ledger"] == ledger and restored["requests"] == self.final["requests"]
                        and restored["steps"] == self.final["steps"]
                        and restored["event_types"] == self.final["event_types"] + ["ProcurementOperatorGrantedV1"],
                        "restored custody binding or quote changed")
        validate_detail(restored, self.trip, self.quote, phase="delivered",
                        operations=["accept", "picked_up", "delivered"], proof_digests=self.proof_digests, revoked=True)
        self.restored = restored
        self.checks["restored_delivery_binding"] = True

    def receipt(self, host: dict) -> dict:
        result = {"kind": KIND, "execution_kind": EXECUTION, "revision": host["revision"],
                  "artifact_sha256": host["artifact_sha256"], "trust": host["trust"],
                  "host_checks": host["checks"], "dispatch_checks": self.checks,
                  "packaged_dispatch_worker": False, "live_delivery": False, "transport": TRANSPORT,
                  "restored_ledger": host["restored_ledger"],
                  "dispatch_evidence": {"source_revision": self.revision, "mix_env": "test",
                      "canonical_appender_in_dispatch": False, "assignment": self.trip,
                      "accepted_quote": self.quote, "canonical_delivery": self.final,
                      "restored_delivery": self.restored,
                      "handoff_code_sha256": self.proof_digests,
                      "observations": self.observations},
                  "scope": "synthetic identities; bundled procurement ERTS plus separate source Dispatch VMs; "
                           "actual service assignment and authenticated courier Router; no external IdP, "
                           "graphical courier, packaged Dispatch or deployment acceptance"}
        validate_receipt(result, self.revision, host["artifact_sha256"])
        return result

    def cleanup(self):
        if self.state.exists():
            result = self.peer("cleanup")
            release.require(result.get("cleaned_up") is True, "Dispatch fixture cleanup did not complete")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--receipts", type=Path, required=True)
    parser.add_argument("--dispatch-project", type=Path, required=True)
    args = parser.parse_args()
    destination = args.receipts.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    receipt_path = destination / "receipt.json"
    receipt_path.unlink(missing_ok=True)
    peer_env = peer_environment(dict(os.environ))
    result = release.acceptance(args.archive.resolve(), args.revision, destination,
        delivery_factory=lambda harness: DispatchDelivery(harness, args.dispatch_project.resolve(), args.revision, peer_env))
    result["log_sha256"] = {path.name: release.digest(path) for path in sorted(destination.glob("*.log"))}
    validate_receipt(result, args.revision, release.digest(args.archive.resolve()))
    receipt_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
