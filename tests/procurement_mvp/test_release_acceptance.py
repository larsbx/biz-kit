"""Runner/negative controls, not a substitute for running the release itself."""
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import release_acceptance as acceptance

REVISION = "a" * 40
ARTIFACT = "b" * 64


def receipt():
    return {"kind": "procurement-packaged-acceptance-v1", "revision": REVISION,
            "artifact_sha256": ARTIFACT, "trust": "unsigned-runner-observation",
            "checks": {name: True for name in acceptance.REQUIRED}}


class ReceiptTests(unittest.TestCase):
    def test_complete_receipt(self):
        acceptance.validate_receipt(receipt(), REVISION, ARTIFACT)

    def test_every_missing_gate_rejected(self):
        for name in acceptance.REQUIRED:
            with self.subTest(name=name):
                value = receipt()
                del value["checks"][name]
                with self.assertRaises(RuntimeError):
                    acceptance.validate_receipt(value, REVISION, ARTIFACT)

    def test_false_skipped_and_truthy_non_boolean_results_rejected(self):
        for result in (False, None, "skipped", "success", 1, [], {}):
            with self.subTest(result=result):
                value = receipt()
                value["checks"]["http_lifecycle"] = result
                with self.assertRaises(RuntimeError):
                    acceptance.validate_receipt(value, REVISION, ARTIFACT)

    def test_wrong_revision_artifact_kind_and_trust_rejected(self):
        for field in ("revision", "artifact_sha256", "kind", "trust"):
            value = receipt()
            value[field] = "wrong"
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                acceptance.validate_receipt(value, REVISION, ARTIFACT)

    def test_extra_gate_cannot_disguise_missing_gate(self):
        value = receipt()
        del value["checks"]["migration"]
        value["checks"]["looks_ok"] = True
        with self.assertRaises(RuntimeError):
            acceptance.validate_receipt(value, REVISION, ARTIFACT)

    def test_old_success_removed_before_a_failed_rerun(self):
        with tempfile.TemporaryDirectory() as folder:
            destination = Path(folder)
            previous = destination / "receipt.json"
            previous.write_text(json.dumps(receipt()))
            argv = ["release_acceptance.py", "--archive", "missing.tar.gz", "--revision", REVISION,
                    "--receipts", str(destination)]
            with patch("sys.argv", argv), patch.object(acceptance, "acceptance", side_effect=RuntimeError("failure")):
                with self.assertRaises(RuntimeError):
                    acceptance.main()
            self.assertFalse(previous.exists())


class SafetyTests(unittest.TestCase):
    def environment(self):
        return {"PROCUREMENT_RELEASE_ACCEPTANCE": acceptance.MODE,
                "EVENTSTORE_USERNAME": "postgres", "EVENTSTORE_PASSWORD": "synthetic",
                "EVENTSTORE_HOST": "localhost", "PGDATABASE": "do_not_touch",
                "PGSERVICE": "production", "PROCUREMENT_GOVERNANCE_SEED_HEX": "not_inherited"}

    def test_requires_explicit_opt_in(self):
        value = self.environment()
        del value["PROCUREMENT_RELEASE_ACCEPTANCE"]
        with self.assertRaises(RuntimeError):
            acceptance.database_environment(value)

    def test_remote_database_and_bad_port_refused(self):
        for key, value in (("EVENTSTORE_HOST", "db.example.org"), ("EVENTSTORE_HOST", "/var/run/postgresql"),
                           ("EVENTSTORE_PORT", "0"), ("EVENTSTORE_PORT", "65536"), ("EVENTSTORE_PORT", "abc")):
            with self.subTest(key=key, value=value), self.assertRaises(RuntimeError):
                acceptance.database_environment(dict(self.environment(), **{key: value}))

    def test_existing_libpq_and_authority_overrides_not_inherited(self):
        value = acceptance.database_environment(self.environment())
        for key in ("PGDATABASE", "PGSERVICE", "PROCUREMENT_GOVERNANCE_SEED_HEX"):
            self.assertNotIn(key, value)
        self.assertEqual(value["PGHOST"], "localhost")

    def archive(self, path, extra=None, revision=REVISION):
        with tarfile.open(path, "w:gz") as bundle:
            for name, data, mode in (
                ("procurement/SOURCE_REVISION", revision.encode(), 0o600),
                ("procurement/bin/procurement", b"#!/bin/sh\n", 0o700),
                ("procurement/erts-test/bin/erlexec", b"placeholder", 0o700),
            ):
                info = tarfile.TarInfo(name)
                info.size, info.mode = len(data), mode
                bundle.addfile(info, io.BytesIO(data))
            if extra:
                bundle.addfile(extra)

    def test_packaged_identity_required(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            archive = path / "artifact.tar.gz"
            self.archive(archive)
            self.assertEqual(acceptance.unpack(archive, path / "unpack", REVISION).name, "procurement")
            with self.assertRaises(RuntimeError):
                acceptance.unpack(archive, path / "wrong", "c" * 40)

    def test_traversal_and_symlink_escape_rejected(self):
        for name, kind, target in (("../outside", tarfile.REGTYPE, ""),
                                  ("procurement/../../outside", tarfile.REGTYPE, ""),
                                  ("procurement/link", tarfile.SYMTYPE, "../../outside")):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as folder:
                path = Path(folder)
                extra = tarfile.TarInfo(name)
                extra.type, extra.linkname = kind, target
                archive = path / "bad.tar.gz"
                self.archive(archive, extra)
                with self.assertRaises((RuntimeError, tarfile.FilterError)):
                    acceptance.unpack(archive, path / "unpack", REVISION)
                self.assertFalse((path / "outside").exists())


class FormTests(unittest.TestCase):
    def test_rendered_hidden_fields_and_entities_preserved(self):
        forms = acceptance.Forms('<form action="/requests/r/accept"><input name="revision" value="2">'
                                 '<input name="_csrf_token" value="a&amp;b"></form>')
        self.assertEqual(forms.one("/accept", suffix=True)["fields"], {"revision": "2", "_csrf_token": "a&b"})

    def test_missing_or_ambiguous_form_refused(self):
        forms = acceptance.Forms('<form action="/login"></form><form action="/login"></form>')
        for action in ("/login", "/missing"):
            with self.assertRaises(RuntimeError):
                forms.one(action)

    def test_protocol_relative_action_refused_before_network(self):
        browser = object.__new__(acceptance.Browser)
        with self.assertRaises(RuntimeError):
            browser.request("//other-host/login")


class TransportTests(unittest.TestCase):
    def test_real_tls_proxy_preserves_secure_cookie_form_and_redirect(self):
        import http.server
        import subprocess
        import threading

        observed = []

        class Backend(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                body = b'<form action="/login"><input name="_csrf_token" value="synthetic"></form>'
                self.send_response(200)
                self.send_header("Cache-Control", "no-store")
                self.send_header("Set-Cookie", "session=synthetic; Secure; HttpOnly; Path=/; SameSite=Strict")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                observed.append((self.headers.get("Cookie"), self.headers.get("X-Forwarded-Proto"), body))
                self.send_response(303)
                self.send_header("Location", "/requests")
                self.send_header("Content-Length", "0")
                self.end_headers()

        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            certificate, key = path / "cert.pem", path / "key.pem"
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                            "-keyout", str(key), "-out", str(certificate), "-subj", "/CN=127.0.0.1",
                            "-addext", "subjectAltName=IP:127.0.0.1"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=15)
            backend = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Backend)
            threading.Thread(target=backend.serve_forever, daemon=True).start()
            tls = acceptance.proxy(backend.server_address[1], certificate, key)
            try:
                browser = acceptance.Browser(f"https://127.0.0.1:{tls.server_address[1]}", certificate)
                form = acceptance.Forms(browser.page("/login")).one("/login")
                _, _, headers = browser.submit(form, {"token": "synthetic"})
                self.assertEqual(headers.get("Location"), "/requests")
                self.assertTrue(any(cookie.secure for cookie in browser.cookies))
                self.assertEqual(observed, [("session=synthetic", "https", b"_csrf_token=synthetic&token=synthetic")])
            finally:
                tls.shutdown()
                tls.server_close()
                backend.shutdown()
                backend.server_close()


if __name__ == "__main__":
    unittest.main()
