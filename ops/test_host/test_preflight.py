"""Host-independent refusal tests for the read-only test-server preflight."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest import mock

MODULE_PATH = Path(__file__).with_name("preflight.py")
SPEC = importlib.util.spec_from_file_location("test_host_preflight", MODULE_PATH)
preflight = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(preflight)


def proc(stdout="", returncode=0):
    return SimpleNamespace(stdout=stdout, returncode=returncode)


class TestHostPreflight(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.reply = {
            "systemctl": proc("running\n"),
            "podman": proc(json.dumps({"host": {"security": {"rootless": True}}})),
            "ss": proc("LISTEN 0 128 127.0.0.1:4567 0.0.0.0:*\n"),
        }

    def dispatch(self, argv):
        self.calls.append(argv)
        return self.reply[argv[0]]

    def run_audit(self, host="test-node", role="test", units=(), free_bytes=10 * 1024 ** 3,
                  inodes=100000, user_id=1000):
        stat = SimpleNamespace(f_bavail=free_bytes // 4096, f_frsize=4096,
                               f_favail=inodes)
        with mock.patch.object(preflight, "command", side_effect=self.dispatch), \
             mock.patch.object(preflight.socket, "gethostname", return_value="test-node"), \
             mock.patch.object(preflight.platform, "system", return_value="Linux"), \
             mock.patch.object(preflight.os, "geteuid", return_value=user_id), \
             mock.patch.object(preflight.os, "statvfs", return_value=stat):
            return preflight.audit(host, role, 4, units)

    def test_healthy_read_only_test_node(self):
        report = self.run_audit(units=("example.service",))
        self.assertEqual(report["result"], "pass")
        self.assertEqual(report["environment"], "test")
        self.assertFalse(report["deployment_authorized"])
        self.assertFalse(report["live_deployment_verified"])
        self.assertEqual(
            self.calls,
            [["systemctl", "--user", "list-units", "--type=service", "--no-pager",
              "--plain", "--no-legend"],
             ["podman", "info", "--format", "json"],
             ["systemctl", "--user", "is-active", "example.service"],
             ["ss", "-H", "-ltn"]]
        )

    def test_wrong_host_fails(self):
        report = self.run_audit(host="other-node")
        self.assertEqual(report["result"], "fail")
        self.assertEqual(report["checks"][0]["check"], "hostname")
        self.assertEqual(report["checks"][0]["status"], "fail")

    def test_root_is_rejected(self):
        report = self.run_audit(user_id=0)
        self.assertEqual(report["result"], "fail")
        self.assertIn("root execution refused", str(report))

    def test_low_storage_and_inodes_fail(self):
        report = self.run_audit(free_bytes=1024, inodes=100)
        self.assertEqual(report["result"], "fail")
        self.assertIn("root_filesystem_headroom", str(report))

    def test_rootful_podman_rejected(self):
        self.reply["podman"] = proc('{"host":{"security":{"rootless":false}}}')
        report = self.run_audit()
        self.assertEqual(report["result"], "fail")
        self.assertIn("rootless runtime not verified", str(report))

    def test_failed_services_fail(self):
        self.reply["systemctl"] = proc("inactive\n", 3)
        report = self.run_audit(units=("app.service",))
        self.assertEqual(report["result"], "fail")
        self.assertIn("requested service not active", str(report))

    def test_listener_warning_does_not_claim_clearance(self):
        self.reply["ss"] = proc("LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n")
        report = self.run_audit()
        self.assertEqual(report["result"], "review")
        self.assertFalse(report["deployment_authorized"])

    def test_errors_are_not_echoed_or_interpolated(self):
        leaked = "SUPER_SECRET=unprintable-value"
        self.reply["podman"] = proc(leaked, 1)
        self.reply["ss"] = proc(leaked, 1)
        report = self.run_audit()
        self.assertNotIn(leaked, json.dumps(report))
        self.assertEqual(report["result"], "fail")

    def test_invalid_target_or_unit_refused_before_any_probe(self):
        for host, role, units in [
            ("test-node", "production", ()),
            ("test-node", "test", ("app.service;rm -rf /",)),
            ("bad host", "test", ()),
        ]:
            with self.subTest(host=host, role=role, units=units):
                with self.assertRaises(ValueError):
                    self.run_audit(host=host, role=role, units=units)
        self.assertEqual(self.calls, [])

    def test_cli_rejects_production_and_requires_explicit_target(self):
        for argv in [
            ["--environment", "production", "--expected-host", "test-node"],
            ["--environment", "test"],
        ]:
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as caught:
                    preflight.main(argv)
                self.assertEqual(caught.exception.code, 2)

    def test_podman_schema_variants_fail_closed(self):
        self.assertTrue(preflight.parse_podman_rootless('{"Host":{"Security":{"Rootless":true}}}'))
        self.assertIsNone(preflight.parse_podman_rootless('{"host":{"security":{}}}'))
        self.assertIsNone(preflight.parse_podman_rootless('not-json'))


if __name__ == "__main__":
    unittest.main()
