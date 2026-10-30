#!/usr/bin/env python3
"""Run the actual workflow shell against a local HTTP fixture, never adder-ws.

Requires PyYAML 6.0.3. No credentials, tailnet, or production service required.
"""
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import os
import subprocess
import tempfile
import threading
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/deploy-adder-ws.yml"
ENDPOINT = "http://100.67.165.25:8791/deploy"


def push_to_main_workflows():
    """Names of the workflows that run on push to main, other than the trigger.

    Their completions are what wake adder-ws, so the trigger must list exactly
    these: a missing one could be the last to finish and leave a green commit
    undeployed until the next push.
    """
    names = []
    for path in sorted(WORKFLOW.parent.glob("*.yml")):
        if path == WORKFLOW:
            continue
        workflow = yaml.load(path.read_text(), Loader=yaml.BaseLoader)
        events = workflow.get("on")
        if not isinstance(events, dict) or "push" not in events:
            continue
        push = events["push"]
        branches = push.get("branches") if isinstance(push, dict) else None
        if branches is None or "main" in branches:
            names.append(workflow["name"])
    return sorted(names)


def contract_errors(workflow):
    errors = []
    job = workflow["jobs"]["trigger"]
    guard = job.get("if", "")
    for required in (
        "github.repository == 'larsbx/biz-kit'",
        "github.ref == 'refs/heads/main'",
        "vars.ADDER_WS_CD == 'true'",
        "vars.ADDER_WS_CD_ACCEPTANCE == 'v1'",
    ):
        if required not in guard or "||" in guard:
            errors.append(required)
    if workflow.get("permissions") != {}:
        errors.append("token permissions")
    if workflow["concurrency"] != {"group": "deploy-adder-ws", "cancel-in-progress": "false"}:
        errors.append("concurrency")
    expected_events = {
        "workflow_run": {
            "workflows": push_to_main_workflows(),
            "types": ["completed"],
            "branches": ["main"],
        },
        "workflow_dispatch": "",
    }
    if workflow["on"] != expected_events:
        errors.append("events")
    action = job["steps"][1]
    if action["uses"] != "tailscale/github-action@064b10558093f38325e838ddea35486bdc6b1d5c":
        errors.append("action pin")
    if action["with"]["tags"] != "tag:biz-kit-deploy":
        errors.append("isolated identity")
    if action["with"]["use-cache"] != "false":
        errors.append("credential job caching")
    if action["with"].get("args") != "--accept-routes=false --accept-dns=false":
        errors.append("unneeded subnet routes or DNS")
    if len(job["steps"]) != 3:
        errors.append("unexpected credential-bearing steps")
    return errors


@contextmanager
def endpoint(status):
    calls = []

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            calls.append((self.command, self.path, self.rfile.read(int(self.headers.get("Content-Length", 0)))))
            self.send_response(status)
            self.send_header("Location", "/must-not-follow")
            self.end_headers()
            self.wfile.write(b"::error::UNTRUSTED_BODY must never enter Actions output")

        def do_GET(self):
            calls.append((self.command, self.path, b""))
            self.send_response(202)
            self.end_headers()

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/deploy", calls
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


class Contract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = yaml.load(WORKFLOW.read_text(), Loader=yaml.BaseLoader)
        cls.job = cls.workflow["jobs"]["trigger"]
        cls.script = cls.job["steps"][2]["run"]

    def run_shell(self, script, extra_env=None):
        with tempfile.TemporaryDirectory() as tmp:
            summary = Path(tmp) / "summary"
            # Hostile curl defaults and proxies must not redirect the request.
            (Path(tmp) / ".curlrc").write_text("request = GET\nlocation\n")
            env = dict(os.environ, CURL_HOME=tmp, GITHUB_STEP_SUMMARY=str(summary),
                       http_proxy="http://127.0.0.1:1", HTTP_PROXY="http://127.0.0.1:1",
                       ALL_PROXY="http://127.0.0.1:1", all_proxy="http://127.0.0.1:1",
                       NO_PROXY="", no_proxy="")
            env.update(extra_env or {})
            result = subprocess.run(["bash", "-euo", "pipefail", "-c", script],
                                    env=env, capture_output=True, text=True, timeout=20)
            return result, summary.read_text() if summary.exists() else ""

    def test_workflow_boundary(self):
        self.assertEqual(contract_errors(self.workflow), [])

    def test_boundary_negative_controls(self):
        # Demonstrate that removing each boundary is detected.
        original = WORKFLOW.read_text()
        mutations = [
            ("github.ref == 'refs/heads/main' && ", ""),
            ("github.repository == 'larsbx/biz-kit' && ", ""),
            (" && vars.ADDER_WS_CD_ACCEPTANCE == 'v1'", ""),
            ("tag:biz-kit-deploy", "tag:ci"),
            ("cancel-in-progress: false", "cancel-in-progress: true"),
            ("permissions: {}", "permissions: {contents: write}"),
            ("      - 'Consolidation'\n", ""),
            ("types: [completed]", "types: [requested]"),
        ]
        for before, after in mutations:
            with self.subTest(mutation=before):
                self.assertIn(before, original)
                mutant = yaml.load(original.replace(before, after), Loader=yaml.BaseLoader)
                self.assertTrue(contract_errors(mutant))

    def test_credentials_fail_closed(self):
        script = self.job["steps"][0]["run"]
        for client, secret in [("", ""), ("", "TEST_SECRET"), ("TEST_CLIENT", "")]:
            with self.subTest(client=bool(client), secret=bool(secret)):
                result, _ = self.run_shell(script, {"TS_CLIENT_ID": client, "TS_CLIENT_SECRET": secret})
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("TEST_SECRET", result.stdout + result.stderr)
        result, _ = self.run_shell(script, {"TS_CLIENT_ID": "TEST_CLIENT", "TS_CLIENT_SECRET": "TEST_SECRET"})
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout + result.stderr, "")

    def test_actual_http_acknowledgement_and_negative_responses(self):
        self.assertEqual(self.script.count(ENDPOINT), 1)
        for status in [202, 200, 204, 301, 302, 307, 400, 401, 403, 404, 409, 500, 503]:
            with self.subTest(status=status), endpoint(status) as (url, calls):
                result, summary = self.run_shell(self.script.replace(ENDPOINT, url))
                self.assertEqual(result.returncode == 0, status == 202)
                self.assertEqual(calls, [("POST", "/deploy", b"")])
                self.assertNotIn("UNTRUSTED_BODY", result.stdout + result.stderr + summary)
                if status == 202:
                    self.assertIn("completion must be verified on adder-ws", summary)
                else:
                    self.assertEqual(summary, "")

    def test_connection_failure_does_not_report_acceptance(self):
        # Reserve, then close a port to obtain a refused local connection.
        with endpoint(202) as (url, _):
            pass
        result, summary = self.run_shell(self.script.replace(ENDPOINT, url))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(summary, "")

    def test_transport_bounds(self):
        for required in ["curl -q", "--noproxy '*'", "--connect-timeout 5", "--max-time 15",
                         "--retry 0", "--output /dev/null", "set -euo pipefail"]:
            self.assertIn(required, self.script)
        for forbidden in ["--location", "--retry-all-errors", "--verbose", "set -x"]:
            self.assertNotIn(forbidden, self.script)

    def test_transport_timeout_does_not_report_acceptance(self):
        # curl can emit a status even when transfer fails. Its exit code must win.
        with tempfile.TemporaryDirectory() as tmp:
            fake_curl = Path(tmp) / "curl"
            fake_curl.write_text("#!/bin/sh\nprintf 202\nexit 28\n")
            fake_curl.chmod(0o700)
            result, summary = self.run_shell(self.script, {"PATH": tmp + os.pathsep + os.environ["PATH"]})
            self.assertEqual(result.returncode, 28)
            self.assertEqual(summary, "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
