#!/usr/bin/env python3
"""Run two bundled ERTS releases with disposable SQL and a private HTTPS trust anchor."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from queue import Queue
import re
import secrets
from urllib.parse import quote

import dispatch_release_acceptance as dispatch
import release_acceptance as release

NAME = "dispatch_acceptance"
KIND = "procurement-dispatch-two-packaged-processes-v1"
EXECUTION = "packaged-procurement-packaged-test-dispatch-postgresql"
TRANSPORT = {
    "coordinator": "verified-loopback-https",
    "dispatch_to_procurement": "verified-loopback-https-origin-scoped-fixture-trust",
    "courier": "authenticated-DispatchWeb.Router-in-packaged-test-vm",
}
REFUSALS = {"unknown_ca", "hostname_check_failed"}


def validate_receipt(value: dict, revision: str, procurement_hash: str, dispatch_hash: str) -> None:
    release.require(value.get("kind") == KIND and value.get("execution_kind") == EXECUTION,
                    "wrong packaged Dispatch acceptance kind")
    release.require(value.get("packaged_dispatch_worker") is True and value.get("live_delivery") is False
                    and value.get("transport") == TRANSPORT, "invalid packaged execution boundary")
    release.validate_receipt({"kind": "procurement-packaged-acceptance-v1", "revision": value.get("revision"),
                              "artifact_sha256": value.get("artifact_sha256"), "trust": value.get("trust"),
                              "checks": value.get("host_checks")}, revision, procurement_hash)
    release.require(value.get("dispatch_artifact_sha256") == dispatch_hash
                    and re.fullmatch(r"[0-9a-f]{64}", dispatch_hash) is not None
                    and dispatch_hash != procurement_hash, "Dispatch archive hash mismatch")
    dispatch.validate_dispatch_evidence(value, revision)
    evidence = value["dispatch_evidence"]
    release.require(evidence.get("mix_env") == "test"
                    and evidence.get("database_scope") == "fresh-separate-loopback-databases",
                    "wrong Dispatch release profile or database scope")
    certificates = evidence.get("certificate_sha256", {})
    release.require(set(certificates) == {"trusted", "wrong_hostname"}
                    and len(set(certificates.values())) == 2
                    and all(re.fullmatch(r"[0-9a-f]{64}", sha) for sha in certificates.values()),
                    "missing distinct TLS fixture certificate identities")
    rows = evidence["observations"]
    release.require(isinstance(rows, list) and all(isinstance(row, dict) for row in rows)
                    and all(row.get("bundled_erts") is True and row.get("ok") is True
                            and row.get("no_canonical_appender") is True for row in rows),
                    "peer action did not run in bundled ERTS without a canonical appender")
    pids = [row.get("source_os_pid") for row in rows]
    release.require(all(isinstance(pid, str) and pid.isdecimal() for pid in pids)
                    and len(set(pids)) == len(rows), "expected a fresh packaged process for each peer action")
    expected = ["migrate", "bootstrap", "tls_probe", "tls_probe", "worker", "worker", "receipt",
                "receipt", "worker", "receipt", "receipt", "worker", "receipt", "worker", "cleanup"]
    release.require([row.get("action") for row in rows] == expected
                    and type(rows[0].get("applied_migrations")) is int
                    and rows[0]["applied_migrations"] > 0 and rows[-1].get("cleaned_up") is True,
                    "missing packaged migration, action or cleanup")
    probes = [row for row in rows if row["action"] == "tls_probe"]
    release.require({row.get("tls_refusal") for row in probes} == REFUSALS
                    and all(row.get("no_http_request") is True for row in probes),
                    "missing precise TLS refusals or a probe forwarded HTTP")
    courier = [row for row in rows if row["action"] == "receipt"]
    release.require([row.get("portal_status") for row in courier] == [422, 200, 422, 200, 200]
                    and all(row.get("unauthenticated_denied") is True
                            and row.get("missing_csrf_denied") is True for row in courier),
                    "packaged courier authorization, CSRF or status evidence is incomplete")


class PackagedDelivery(dispatch.DispatchDelivery):
    def __init__(self, harness: release.Harness, origin: str, archive: Path, revision: str):
        project = release.unpack(archive, harness.work, revision, name=NAME)
        release.require((project / "acceptance/dispatch_peer.exs").is_file()
                        and bool(list((project / "lib").glob("dispatch-*/ebin/Elixir.Dispatch.Application.beam")))
                        and not list((project / "lib").glob("procurement_host-*")),
                        "Dispatch acceptance archive lacks the packaged worker or includes ProcurementHost")
        env = {
            "PATH": os.defpath,
            "HOME": str(harness.work),
            "LANG": "C.UTF-8",
            "RELEASE_DISTRIBUTION": "none",
            "PROCUREMENT_DISPATCH_ACCEPTANCE": release.MODE,
            "DISPATCH_ACCEPTANCE_ROOT": str(project),
            "DISPATCH_ACCEPTANCE_INPUT": str(harness.work / "dispatch-input.json"),
            "DISPATCH_ACCEPTANCE_SESSION_KEY": secrets.token_hex(64),
        }
        super().__init__(harness, project, revision, env)
        self.config["origin"] = origin
        self.archive_hash = release.digest(archive)
        self.certificates: dict[str, str] = {}

    def peer_command(self) -> list[str]:
        return [str(self.project / "bin" / NAME), "eval", 'Code.eval_file("acceptance/dispatch_peer.exs")']

    def prepare(self):
        self.prepare_identity()

    def prepare_database(self):
        database = "dispatch_acceptance_" + secrets.token_hex(6)
        env = self.harness.env
        self.harness.create_database(database)
        user, password = (quote(env[name], safe="") for name in ("PGUSER", "PGPASSWORD"))
        self.env["DATABASE_URL"] = f"ecto://{user}:{password}@127.0.0.1:{env['PGPORT']}/{database}"
        observed = self.peer("migrate")
        release.require(observed.get("applied_migrations", 0) > 0, "packaged Dispatch did not migrate")

    def probe(self, certificate: Path, key: Path, refusal: str):
        received = Queue()
        proxy = release.proxy(int(self.harness.env["PROCUREMENT_PORT"]), certificate, key, received=received)
        try:
            origin = f"https://127.0.0.1:{proxy.server_address[1]}"
            observed = self.peer("tls_probe", probe_origin=origin, expected_tls_error=refusal)
            release.require(observed.get("tls_refusal") == refusal and received.empty(),
                            "the worker did not refuse the TLS probe before forwarding HTTP")
            self.observations[-1]["no_http_request"] = True
        finally:
            proxy.shutdown()
            proxy.server_close()

    def handoff(self, browser: release.Browser, path: str, quote: dict) -> str:
        work = self.harness.work
        wrong_cert, wrong_key = work / "wrong-tls.crt", work / "wrong-tls.key"
        self.harness.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                          "-keyout", str(wrong_key), "-out", str(wrong_cert), "-subj", "/CN=wrong.invalid",
                          "-addext", "subjectAltName=DNS:wrong.invalid"], label="wrong-host-certificate")
        self.certificates = {"trusted": release.digest(work / "tls.crt"),
                             "wrong_hostname": release.digest(wrong_cert)}
        self.probe(work / "tls.crt", work / "tls.key", "unknown_ca")
        self.probe(wrong_cert, wrong_key, "hostname_check_failed")
        return super().handoff(browser, path, quote)

    def receipt(self, host: dict) -> dict:
        value = self.evidence(host)
        value.update(kind=KIND, execution_kind=EXECUTION, transport=TRANSPORT,
                     packaged_dispatch_worker=True, dispatch_artifact_sha256=self.archive_hash,
                     scope="two independent bundled releases on one loopback host; synthetic identities, "
                           "Dispatch test profile, and authenticated in-process Router")
        value["dispatch_evidence"].update(database_scope="fresh-separate-loopback-databases",
                                          certificate_sha256=self.certificates)
        # The parent completes Dispatch and PostgreSQL cleanup before validation and writing.
        return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--procurement-archive", required=True, type=Path)
    parser.add_argument("--dispatch-archive", required=True, type=Path)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--receipts", required=True, type=Path)
    args = parser.parse_args()
    destination = args.receipts.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    receipt = destination / "receipt.json"
    receipt.unlink(missing_ok=True)
    for log in destination.glob("*.log"):
        log.unlink()
    release.require(os.environ.get("PROCUREMENT_DISPATCH_ACCEPTANCE") == release.MODE
                    and os.environ.get("EVENTSTORE_HOST", "127.0.0.1") == "127.0.0.1",
                    "explicit disposable IPv4 loopback PostgreSQL is required")
    procurement_archive = args.procurement_archive.resolve()
    dispatch_archive = args.dispatch_archive.resolve()
    result = release.acceptance(procurement_archive, args.revision, destination,
        delivery_factory=lambda harness, origin: PackagedDelivery(harness, origin, dispatch_archive, args.revision))
    validate_receipt(result, args.revision, release.digest(procurement_archive), release.digest(dispatch_archive))
    result["log_sha256"] = {path.name: release.digest(path) for path in sorted(destination.glob("*.log"))}
    temporary = receipt.with_suffix(".tmp")
    temporary.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    temporary.replace(receipt)
    print(f"Accepted two packaged processes at {args.revision}: {receipt}")


if __name__ == "__main__":
    main()
