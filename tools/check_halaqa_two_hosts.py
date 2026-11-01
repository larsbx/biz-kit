"""Operator-run, synthetic relay acceptance roles; never production deployment.

Each role owns a fresh disposable PostgreSQL cluster. Reports check consistency,
not physical-host independence, remote attestation, governance or business authority.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import secrets
import time
import subprocess

from halaqa_iroh_draft import IrohReceiptPeer, IrohReceiverFixture, identity, strict_json, check_path
from halaqa_receipt_draft import ROOT
from test_halaqa_outbox_draft import TwoDatabaseTestCase

SOURCE_FILES = ["tools/halaqa_iroh_draft_rs/Cargo.lock", "tools/halaqa_iroh_draft_rs/src/main.rs",
                "tools/halaqa_iroh_draft_rs/Cargo.toml", "tools/check_halaqa_federation_draft.py",
                "tools/halaqa_federation_draft/halaqa_federation_draft.py",
                "tools/halaqa_federation_draft/halaqa_federation_signed_draft.py",
                "tools/halaqa_federation_draft/signed-vectors.json",
                "tools/test_halaqa_receipt_draft.py", "tools/test_halaqa_outbox_draft.py",
                "tools/halaqa_iroh_draft.py", "tools/halaqa_outbox_draft.py",
                "tools/halaqa_receipt_draft.py", "tools/halaqa_receipt_draft/schema.sql",
                "tools/halaqa_receipt_draft/outbox.sql", "tools/halaqa_federation_draft/source-pin.json",
                "tools/check_halaqa_two_hosts.py"]


def read_json(path):
    return strict_json(Path(path).read_bytes(), 128_000)


def write_json(path, value):
    # Reports contain public fixture IDs/hashes, never private endpoint keys.
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def initialize(directory, role, binary):
    directory = Path(directory)
    directory.mkdir(mode=0o700)  # Never replace an existing identity bundle.
    key = directory / "endpoint.key"
    key.write_bytes(secrets.token_bytes(32))
    key.chmod(0o600)
    public = {"schema": "halaqa-host-fixture-identity/0", "role": role,
              "endpoint": identity(binary, key)}
    write_json(directory / "public.json", public)
    return public


def inputs(args, role):
    if re.fullmatch(r"[0-9a-f]{40}", args.revision) is None:
        raise ValueError("exact 40-character source revision required")
    if not args.host_label or len(args.host_label) > 64:
        raise ValueError("operator host label required")
    if not args.local_rehearsal:
        head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True,
                              capture_output=True, check=True).stdout.strip()
        changes = subprocess.run(["git", "status", "--porcelain", "--", *SOURCE_FILES], cwd=ROOT,
                                 text=True, capture_output=True, check=True).stdout
        if head != args.revision or changes:
            raise ValueError("clean exact-revision checkout required; local rehearsal must be explicitly labeled")
    own = read_json(Path(args.identity_dir) / "public.json")
    remote = read_json(args.peer_public)
    for value, expected in ((own, role), (remote, "receiver" if role == "sender" else "sender")):
        if set(value) != {"schema", "role", "endpoint"} or value["schema"] != "halaqa-host-fixture-identity/0" or value["role"] != expected:
            raise ValueError("wrong fixture identity role/schema")
    key = Path(args.identity_dir) / "endpoint.key"
    if identity(args.binary, key) != own["endpoint"] or own["endpoint"] == remote["endpoint"]:
        raise ValueError("local key/public descriptor mismatch or identical peers")
    relay = {"url": args.relay_url, "ca_file": str(Path(args.ca_file).resolve())}
    return own, remote, key, relay


def base_report(args, own, remote, relay, wire, candidate):
    return {"schema": "halaqa-two-host-fixture-report/0", "role": own["role"],
            "implementation_revision": args.revision, "host_label": args.host_label,
            "checkout_state": "local_rehearsal_unverified" if args.local_rehearsal else "clean_git_head",
            "own_endpoint": own["endpoint"], "peer_endpoint": remote["endpoint"],
            "relay_url": relay["url"].rstrip("/") + "/",
            "candidate_sha256": hashlib.sha256(candidate).hexdigest(),
            "wire_sha256": hashlib.sha256(wire).hexdigest(),
            "source_sha256": {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in SOURCE_FILES},
            "authority_verified": False, "production_receiver": False,
            "host_provenance": "operator label; physical independence not attested"}


class IsolatedHost(TwoDatabaseTestCase):
    """Reuse disposable-cluster acceptance setup; do not run its test methods."""


def fixture():
    corpus = strict_json((ROOT / "tools/halaqa_federation_draft/signed-vectors.json").read_bytes(), 2_000_000)
    vector = corpus["vectors"][0]
    wire = base64.b64decode(vector["wire_base64"])
    candidate = base64.b64decode(json.loads(wire)["candidate"])
    return wire, dict(vector["test_policy"]), candidate


def serve(args):
    own, remote, key, relay = inputs(args, "receiver")
    if not 1 <= args.duration <= 300:
        raise ValueError("receiver duration must be 1..300 seconds")
    wire, policy, candidate = fixture()
    server = None
    history, evidence, restarted, delivery_count = [], [], False, 0
    try:
        IsolatedHost.setUpClass()
        server = IrohReceiverFixture(args.binary, key, remote["endpoint"], IsolatedHost.receiver, policy, relay)
        server.drop_next_delivery_reply = True
        print(json.dumps({"event": "receiver_ready", "endpoint": own["endpoint"]}), flush=True)
        deadline = time.monotonic() + args.duration
        try:
            while time.monotonic() < deadline:
                if not restarted and not server.drop_next_delivery_reply:
                    history += server.requests
                    evidence += server.path_evidence
                    delivery_count += server.delivery_count
                    server.close()
                    policy.update({"now": json.loads(wire)["expires_at"], "revoked": True})
                    server = IrohReceiverFixture(args.binary, key, remote["endpoint"], IsolatedHost.receiver, policy, relay)
                    restarted = True
                    print(json.dumps({"event": "receiver_restarted", "endpoint": own["endpoint"]}), flush=True)
                if server.error:
                    raise RuntimeError("fixture host channel failed") from server.error
                time.sleep(0.05)
        except KeyboardInterrupt:
            pass  # Ctrl-C finishes the public report and cleans up owned processes.
        history += server.requests
        evidence += server.path_evidence
        message = json.loads(candidate)
        receipt = IsolatedHost.receiver.status(policy["recipient"], policy["sender"], message["message_id"],
                                               hashlib.sha256(candidate).digest())
        report = base_report(args, own, remote, relay, wire, candidate)
        report.update({"state": "RECEIVER_RETAINED", "native_restarted": restarted,
                       "delivery_count": delivery_count + server.delivery_count,
                       "receipt": receipt, "paths": evidence, "requests": history})
        write_json(args.report, report)
        return report
    finally:
        if server:
            server.close()
        IsolatedHost.doClassCleanups()


def send(args):
    own, remote, key, relay = inputs(args, "sender")
    wire, policy, candidate = fixture()
    try:
        IsolatedHost.setUpClass()
        staged = IsolatedHost.sender.stage(wire, policy)
        target = {"id": remote["endpoint"], "addrs": [{"Relay": relay["url"]}]}
        peer = IrohReceiptPeer(args.binary, key, target, policy["sender"], policy["recipient"], relay)
        try:
            IsolatedHost.sender.advance(staged["intent_id"], peer, policy)
        except (subprocess.SubprocessError, OSError):
            pass
        unknown = IsolatedHost.sender.intent(staged["intent_id"])
        if unknown["state"] != "UNKNOWN":
            raise ValueError("required lost-first-reply scenario was not observed")
        expired = {**policy, "now": json.loads(wire)["expires_at"], "revoked": True}
        result = unknown
        for _ in range(4):
            time.sleep(0.2)
            try:
                result = IsolatedHost.sender.advance(staged["intent_id"], peer, expired)
            except (subprocess.SubprocessError, OSError):
                continue
            if result["state"] == "CONFIRMED_TEST_ONLY":
                break
        if result["state"] != "CONFIRMED_TEST_ONLY":
            raise ValueError("original intent did not reconcile")
        report = base_report(args, own, remote, relay, wire, candidate)
        report.update({"state": result["state"], "unknown_before_recovery": True,
                       "generation": result["generation"], "receipt": result["remote_receipt"],
                       "paths": peer.path_evidence})
        write_json(args.report, report)
        return report
    finally:
        IsolatedHost.doClassCleanups()


def compare_reports(sender, receiver, expected_revision):
    def require(value, message):
        if not value:
            raise ValueError(message)
    require(re.fullmatch(r"[0-9a-f]{40}", expected_revision) is not None, "exact revision required")
    for report, role in ((sender, "sender"), (receiver, "receiver")):
        require(report["schema"] == "halaqa-two-host-fixture-report/0" and report["role"] == role, "report role/schema")
        require(report["implementation_revision"] == expected_revision, "implementation revision mismatch")
        require(report["authority_verified"] is False and report["production_receiver"] is False, "authority amplification")
        require(report["checkout_state"] in ("local_rehearsal_unverified", "clean_git_head"), "unknown checkout evidence")
        require(bool(report["paths"]), "no path evidence")
        for path in report["paths"]:
            check_path(path, {"url": report["relay_url"]})
    require(sender["own_endpoint"] == receiver["peer_endpoint"] and sender["peer_endpoint"] == receiver["own_endpoint"], "endpoint pins do not cross-match")
    require(sender["own_endpoint"] != sender["peer_endpoint"], "identical endpoint identities")
    require(sender["host_label"] != receiver["host_label"], "host labels must differ; labels alone do not prove hosts")
    for field in ("checkout_state", "relay_url", "candidate_sha256", "wire_sha256", "source_sha256", "receipt"):
        require(sender[field] == receiver[field], "mismatched " + field)
    require(set(sender["source_sha256"]) == set(SOURCE_FILES), "incomplete source inventory")
    require(sender["source_sha256"] == {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in SOURCE_FILES}, "reports do not match this source checkout")
    require(sender["state"] == "CONFIRMED_TEST_ONLY" and sender["unknown_before_recovery"] is True, "missing sender recovery")
    require(receiver["state"] == "RECEIVER_RETAINED" and receiver["native_restarted"] is True and receiver["delivery_count"] == 1, "missing receiver restart or duplicate delivery")
    require(sender["receipt"]["status"] == "STORED_TEST_ONLY" and sender["receipt"]["candidate_sha256"] == sender["candidate_sha256"], "unbound retained receipt")
    require(sender["receipt"]["authority_verified"] is False and sender["receipt"]["production_receiver"] is False, "receipt authority amplification")
    wire, policy, candidate = fixture()
    require(sender["candidate_sha256"] == hashlib.sha256(candidate).hexdigest()
            and sender["wire_sha256"] == hashlib.sha256(wire).hexdigest(), "different source fixture")
    message = json.loads(candidate)
    require(all(sender["receipt"][k] == message[k] for k in ("sender", "recipient", "message_id")), "receipt scope mismatch")
    return {"schema": "halaqa-two-host-report-check/0",
            "result": "PAIR_CONSISTENT_HOST_PROVENANCE_UNVERIFIED",
            "implementation_revision": expected_revision,
            "checkout_verified": sender["checkout_state"] == "clean_git_head",
            "separate_hosts_verified": False,
            "authority_verified": False, "production_receiver": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default=str(ROOT / "tools/halaqa_iroh_draft_rs/target/debug/halaqa-iroh-delivery-experiment"))
    commands = parser.add_subparsers(dest="command", required=True)
    init = commands.add_parser("init")
    init.add_argument("role", choices=("sender", "receiver"))
    init.add_argument("directory")
    for mode in ("serve", "send"):
        command = commands.add_parser(mode)
        for name in ("identity-dir", "peer-public", "relay-url", "ca-file", "revision", "host-label", "report"):
            command.add_argument("--" + name, required=True)
        command.add_argument("--local-rehearsal", action="store_true",
                             help="label a local rehearsal; bypass clean Git head check without claiming acceptance")
        if mode == "serve":
            command.add_argument("--duration", type=int, default=60)
    check = commands.add_parser("compare")
    check.add_argument("--sender", required=True)
    check.add_argument("--receiver", required=True)
    check.add_argument("--revision", required=True)
    args = parser.parse_args()
    if args.command == "init":
        result = initialize(args.directory, args.role, args.binary)
    elif args.command == "serve":
        result = serve(args)
    elif args.command == "send":
        result = send(args)
    else:
        result = compare_reports(read_json(args.sender), read_json(args.receiver), args.revision)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
