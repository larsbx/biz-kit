import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import dispatch_release_acceptance as source
import packaged_dispatch_acceptance as packaged
import release_acceptance as release
from test_dispatch_release_controls import ARTIFACT, REVISION, receipt

DISPATCH_HASH = "d" * 64


def packaged_receipt():
    value = receipt()
    value.update(kind=packaged.KIND, execution_kind=packaged.EXECUTION, transport=packaged.TRANSPORT,
                 packaged_dispatch_worker=True, dispatch_artifact_sha256=DISPATCH_HASH)
    actions = ["migrate", "bootstrap", "tls_probe", "tls_probe", "worker", "worker", "receipt",
               "receipt", "worker", "receipt", "receipt", "worker", "receipt", "worker", "cleanup"]
    observed = [dict(action=action, bundled_erts=True, ok=True, no_canonical_appender=True,
                     source_os_pid=str(i + 100)) for i, action in enumerate(actions)]
    observed[0]["applied_migrations"] = 15
    observed[-1]["cleaned_up"] = True
    for row, reason in zip(observed[2:4], ("unknown_ca", "hostname_check_failed"), strict=True):
        row.update(tls_refusal=reason, no_http_request=True)
    for row, status in zip(filter(lambda row: row["action"] == "receipt", observed),
                           (422, 200, 422, 200, 200), strict=True):
        row.update(portal_status=status, unauthenticated_denied=True, missing_csrf_denied=True)
    value["dispatch_evidence"].update(mix_env="test", database_scope="fresh-separate-loopback-databases",
                                      certificate_sha256={"trusted": "c" * 64, "wrong_hostname": "e" * 64},
                                      observations=observed)
    return value


class PackagedControls(unittest.TestCase):
    def validate(self, value):
        packaged.validate_receipt(value, REVISION, ARTIFACT, DISPATCH_HASH)

    def test_two_archive_evidence_is_distinct_from_source(self):
        value = packaged_receipt()
        self.validate(value)
        with self.assertRaises(RuntimeError):
            source.validate_receipt(value, REVISION, ARTIFACT)

    def test_refuses_overclaims_wrong_artifacts_and_transport(self):
        for key, wrong in (("revision", "f" * 40), ("dispatch_artifact_sha256", ARTIFACT),
                           ("artifact_sha256", DISPATCH_HASH), ("packaged_dispatch_worker", False),
                           ("transport", source.TRANSPORT), ("live_delivery", True)):
            value = packaged_receipt()
            value[key] = wrong
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                self.validate(value)

    def test_requires_cold_packaged_peers_migration_and_cleanup(self):
        for i, key, wrong in ((0, "applied_migrations", True), (1, "source_os_pid", "100"),
                              (4, "bundled_erts", 1), (5, "no_canonical_appender", False),
                              (-1, "cleaned_up", False)):
            value = packaged_receipt()
            value["dispatch_evidence"]["observations"][i][key] = wrong
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                self.validate(value)

    def test_requires_precise_tls_and_courier_refusals(self):
        for i, key, wrong in ((2, "tls_refusal", "timeout"), (3, "no_http_request", False),
                              (6, "portal_status", 200), (7, "missing_csrf_denied", False),
                              (7, "unauthenticated_denied", False)):
            value = packaged_receipt()
            value["dispatch_evidence"]["observations"][i][key] = wrong
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                self.validate(value)

    def test_peer_is_launched_from_archive_and_receives_only_fixture_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            package = work / "fixture" / packaged.NAME
            library = package / "lib/dispatch-0.1.0/ebin"
            for path in (library, package / "acceptance", package / "erts-test/bin", package / "bin"):
                path.mkdir(parents=True)
            for path in (library / "Elixir.Dispatch.Application.beam", package / "acceptance/dispatch_peer.exs",
                         package / "erts-test/bin/erlexec", package / "bin" / packaged.NAME):
                path.touch(mode=0o700)
            (package / "SOURCE_REVISION").write_text(REVISION + "\n")
            archive = work / "dispatch.tar.gz"
            with tarfile.open(archive, "w:gz") as bundle:
                bundle.add(package, arcname=packaged.NAME)
            env = {"PROCUREMENT_PORT": "9001", "PROCUREMENT_CHAPTER": "chapter",
                   "PROCUREMENT_COOPERATIVE": "cooperative", "EVENTSTORE_PASSWORD": "private",
                   "PROCUREMENT_GOVERNANCE_SEED_HEX": "private"}
            harness = release.Harness(work, work, work, env)
            with self.assertRaisesRegex(RuntimeError, "source revision mismatch"):
                packaged.PackagedDelivery(harness, "https://127.0.0.1:9002", archive, "c" * 40)
            peer = packaged.PackagedDelivery(harness, "https://127.0.0.1:9002", archive, REVISION)
            self.assertEqual(peer.peer_command()[:2], [str(work / packaged.NAME / "bin" / packaged.NAME), "eval"])
            self.assertEqual(peer.config["origin"], "https://127.0.0.1:9002")
            self.assertFalse(set(peer.env) & set(env))
            self.assertNotIn("MIX_ENV", peer.env)

    def test_failed_opt_in_removes_stale_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "receipt.json"
            target.write_text(json.dumps(packaged_receipt()))
            argv = ["packaged_dispatch_acceptance.py", "--procurement-archive", "unused",
                    "--dispatch-archive", "unused", "--revision", REVISION, "--receipts", directory]
            with patch("sys.argv", argv), patch.dict(os.environ, {}, clear=True), self.assertRaises(RuntimeError):
                packaged.main()
            self.assertFalse(target.exists())


if __name__ == "__main__":
    unittest.main()
