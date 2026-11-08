#!/usr/bin/env python3
"""Exercise the packaged procurement release, never Mix or test BEAM files.

Uses synthetic identities and freshly created loopback PostgreSQL databases.
The HTTPS proxy is a test fixture, not a production proxy configuration. Success
is an unsigned runner observation, not implementation refinement or deployment
approval. No receipt is written unless every required check completes.
"""
from __future__ import annotations

import argparse
import hashlib
import http.client
import http.cookiejar
import http.server
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import socket
import ssl
import subprocess
import tarfile
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

REQUIRED = frozenset({
    "packaged_identity", "migration", "unauthenticated_denied", "csrf_denied",
    "http_lifecycle", "obsolete_quote_denied", "exact_retry_inert",
    "restart_replay", "revoked_session_denied", "revoked_write_inert",
    "backup_restore_equal", "restored_revocation_denied",
})
MODE = "disposable-local-postgres"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def validate_receipt(value: dict, revision: str, artifact_sha256: str) -> None:
    require(value.get("kind") == "procurement-packaged-acceptance-v1", "wrong receipt kind")
    require(value.get("revision") == revision, "receipt revision mismatch")
    require(value.get("artifact_sha256") == artifact_sha256, "receipt artifact mismatch")
    checks = value.get("checks")
    require(isinstance(checks, dict) and set(checks) == REQUIRED, "missing or extra acceptance checks")
    require(all(result is True for result in checks.values()), "failed/skipped acceptance check")
    require(value.get("trust") == "unsigned-runner-observation", "incorrect evidence trust label")


def unpack(archive: Path, destination: Path, revision: str) -> Path:
    require(bool(re.fullmatch(r"[0-9a-f]{40}", revision)), "expected a full source revision")
    with tarfile.open(archive, "r:gz") as bundle:
        members = bundle.getmembers()
        require(bool(members), "empty release archive")
        require(all(m.name == "procurement" or m.name.startswith("procurement/") for m in members),
                "archive contains files outside the release root")
        bundle.extractall(destination, members=members, filter="data")
    root = destination / "procurement"
    require((root / "SOURCE_REVISION").read_text().strip() == revision, "packaged source revision mismatch")
    require(os.access(root / "bin/procurement", os.X_OK), "packaged executable missing")
    require(bool(list(root.glob("erts-*/bin/erlexec"))), "packaged ERTS missing")
    return root


def database_environment(source: dict[str, str]) -> dict[str, str]:
    require(source.get("PROCUREMENT_RELEASE_ACCEPTANCE") == MODE, "explicit disposable database opt-in required")
    host = source.get("EVENTSTORE_HOST", "127.0.0.1")
    require(host in {"127.0.0.1", "localhost", "::1"}, "only loopback PostgreSQL is allowed")
    port = source.get("EVENTSTORE_PORT", "5432")
    require(port.isdigit() and 1 <= int(port) <= 65535, "invalid PostgreSQL port")
    require(bool(source.get("EVENTSTORE_USERNAME")), "EVENTSTORE_USERNAME is required")
    require(bool(source.get("EVENTSTORE_PASSWORD")), "EVENTSTORE_PASSWORD is required")
    # Do not inherit another service/database or libpq connection override.
    env = {k: v for k, v in source.items() if not k.startswith(("PG", "PROCUREMENT_", "RELEASE_"))}
    env.update(PGHOST=host, PGPORT=port, PGUSER=source["EVENTSTORE_USERNAME"],
               PGPASSWORD=source["EVENTSTORE_PASSWORD"], PGCONNECT_TIMEOUT="5",
               EVENTSTORE_HOST=host, EVENTSTORE_PORT=port,
               PROCUREMENT_RELEASE_ACCEPTANCE=MODE, RELEASE_DISTRIBUTION="none")
    return env


class Forms(HTMLParser):
    def __init__(self, html: str):
        super().__init__(convert_charrefs=True)
        self.forms: list[dict] = []
        self.current: dict | None = None
        self.feed(html)

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if tag == "form":
            self.current = {"action": attrs.get("action", ""), "fields": {}}
            self.forms.append(self.current)
        elif tag == "input" and self.current is not None and attrs.get("name"):
            self.current["fields"][attrs["name"]] = attrs.get("value", "")

    def handle_endtag(self, tag):
        if tag == "form":
            self.current = None

    def one(self, action: str, *, suffix: bool = False) -> dict:
        rows = [f for f in self.forms if (f["action"].endswith(action) if suffix else f["action"] == action)]
        require(len(rows) == 1, "missing or ambiguous rendered form: " + action)
        return rows[0]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        return None


class Browser:
    """Real TLS HTTP and Secure cookies, but not a graphical browser engine."""
    def __init__(self, url: str, certificate: Path):
        self.url = url
        self.cookies = http.cookiejar.CookieJar()
        self.client = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), NoRedirect(),
            urllib.request.HTTPCookieProcessor(self.cookies),
            urllib.request.HTTPSHandler(context=ssl.create_default_context(cafile=str(certificate))))

    def request(self, path: str, fields: dict | None = None) -> tuple[int, str, object]:
        require(path.startswith("/") and not path.startswith("//"), "non-local form action")
        data = None if fields is None else urllib.parse.urlencode(fields).encode()
        headers = {} if data is None else {"Content-Type": "application/x-www-form-urlencoded", "Origin": self.url}
        request = urllib.request.Request(self.url + path, data=data, headers=headers)
        try:
            response = self.client.open(request, timeout=15)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.status, response.read().decode("utf-8"), response.headers

    def page(self, path: str) -> str:
        status, body, headers = self.request(path)
        require(status == 200, f"expected authenticated page at {path}; got {status}")
        require(headers.get("Cache-Control") == "no-store", "private page is cacheable")
        return body

    def submit(self, form: dict, fields: dict, expected: int = 303):
        values = dict(form["fields"], **fields)
        status, body, headers = self.request(form["action"], values)
        require(status == expected, f"form {form['action']} returned {status}, expected {expected}")
        return values, body, headers

    def denied(self, path: str, fields: dict | None = None) -> None:
        status, _, headers = self.request(path, fields)
        require(status == 303 and headers.get("Location") == "/login", "revoked/unauthenticated request admitted")


def proxy(backend_port: int, certificate: Path, key: Path):
    class Forward(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass  # No cookies, credentials or request bodies in receipts.

        def do_GET(self):
            self.forward()

        def do_POST(self):
            self.forward()

        def forward(self):
            length = int(self.headers.get("Content-Length", "0"))
            if length > 16_384:
                self.send_error(413)
                return
            body = self.rfile.read(length) if length else None
            headers = {k: v for k, v in self.headers.items() if k.lower() not in {"connection", "transfer-encoding"}}
            headers["X-Forwarded-Proto"] = "https"
            connection = http.client.HTTPConnection("127.0.0.1", backend_port, timeout=15)
            try:
                connection.request(self.command, self.path, body=body, headers=headers)
                result = connection.getresponse()
                payload = result.read()
                self.send_response(result.status)
                for name, value in result.getheaders():
                    if name.lower() not in {"connection", "transfer-encoding", "content-length"}:
                        self.send_header(name, value)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            except (OSError, http.client.HTTPException):
                self.send_error(502)
            finally:
                connection.close()

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Forward)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


class Harness:
    def __init__(self, root: Path, work: Path, receipts: Path, env: dict[str, str]):
        self.root, self.work, self.receipts, self.env = root, work, receipts, env
        self.executable = str(root / "bin/procurement")
        self.child = None
        self.output = None
        self.databases: list[str] = []
        self.counter = 0

    def run(self, args: list[str], *, env=None, label="command", timeout=90) -> str:
        self.counter += 1
        output = self.receipts / f"{self.counter:02d}-{label}.log"
        with output.open("w") as log:
            result = subprocess.run(args, cwd=self.root, env=env or self.env, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=timeout, check=False)
        require(result.returncode == 0, f"{label} failed; see {output.name}")
        return output.read_text()

    def create_database(self, name: str):
        self.run(["createdb", "--maintenance-db=postgres", "--template=template0", name], label="createdb")
        self.databases.append(name)  # Never drop a database this process did not create.

    def fixture(self, mode: str) -> dict:
        require(self.child is None, "offline fixture cannot run beside a live appender")
        env = dict(self.env, PROCUREMENT_ENABLED="false", PROCUREMENT_FIXTURE_MODE=mode)
        script = Path(__file__).with_name("release_fixture.exs").resolve()
        env["PROCUREMENT_FIXTURE_FILE"] = str(script)
        text = self.run([self.executable, "eval", 'Code.eval_file(System.fetch_env!("PROCUREMENT_FIXTURE_FILE"))'],
                        env=env, label=mode)
        prefix = "PROCUREMENT_FIXTURE_JSON:"
        rows = [line[len(prefix):] for line in text.splitlines() if line.startswith(prefix)]
        require(len(rows) == 1, "missing or ambiguous packaged fixture result")
        return json.loads(rows[0])

    def start(self):
        require(self.child is None, "release already running")
        self.counter += 1
        self.output = (self.receipts / f"{self.counter:02d}-release.log").open("w")
        # Offline authority never enters the long-running host environment.
        env = {k: v for k, v in self.env.items() if not k.startswith("PROCUREMENT_GOVERNANCE_")}
        env["PROCUREMENT_ENABLED"] = "true"
        self.child = subprocess.Popen([self.executable, "start"], cwd=self.root, env=env,
                                      stdout=self.output, stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            require(self.child.poll() is None, "packaged release exited before readiness")
            connection = http.client.HTTPConnection("127.0.0.1", int(env["PROCUREMENT_PORT"]), timeout=1)
            try:
                connection.request("GET", "/healthz")
                result = connection.getresponse()
                if result.status == 200 and result.read() == b"procurement-host\n":
                    return
            except (OSError, http.client.HTTPException):
                pass
            finally:
                connection.close()
            time.sleep(0.1)
        raise RuntimeError("packaged release did not become healthy")

    def stop(self, *, cleanup=False):
        if self.child is not None:
            child, self.child = self.child, None
            alive = child.poll() is None
            if alive:
                os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=5)
                if not cleanup:
                    raise RuntimeError("release required forced termination")
            finally:
                if self.output:
                    self.output.close()
                    self.output = None
            require(cleanup or alive, "release exited unexpectedly before shutdown")

    def cleanup(self):
        self.stop(cleanup=True)
        errors = []
        for database in reversed(self.databases):
            try:
                self.run(["dropdb", "--if-exists", "--maintenance-db=postgres", database], label="dropdb")
            except Exception as error:
                errors.append(str(error))
        require(not errors, "temporary database cleanup failed: " + "; ".join(errors))


def lifecycle(browser: Browser, token: str, checks: dict) -> tuple[str, dict]:
    browser.denied("/requests")
    checks["unauthenticated_denied"] = True
    login = Forms(browser.page("/login")).one("/login")
    _, body, _ = browser.submit(login, {"token": token})
    require(token not in body, "credential reflected by login")
    page = browser.page("/requests")
    require(any(cookie.secure for cookie in browser.cookies), "no Secure session cookie")
    create = Forms(page).one("/request", suffix=True)
    request_path = create["action"].rsplit("/", 1)[0]
    invalid = dict(create["fields"])
    invalid.pop("_csrf_token", None)
    status, _, _ = browser.request(create["action"], invalid)
    require(status == 403, "missing CSRF did not produce a refusal")
    checks["csrf_denied"] = True
    future = time.strftime("%Y-%m-%dT%H:%M", time.gmtime(time.time() + 86_400))
    original, _, _ = browser.submit(create, {
        "buyer_business_id": "acceptance-buyer", "description": "<script>synthetic packaging</script>",
        "quantity": "4", "currency": "USD", "needed_by_ms": future, "consent_ref": "synthetic-consent"})
    page = browser.page(request_path)
    require("<script>" not in page and "&lt;script&gt;" in page, "description was not escaped")
    browser.submit(Forms(page).one("/qualify", suffix=True), {"evidence_ref": "synthetic-qualified"})
    quote = {"quote_id": "acceptance-quote", "merchant_business_id": "acceptance-merchant",
             "revision": "1", "total_minor": "12000", "expires_at_ms": future, "source_ref": "synthetic-quote-1"}
    browser.submit(Forms(browser.page(request_path)).one("/quote", suffix=True), quote)
    page = browser.page(request_path)
    old_accept = Forms(page).one("/accept", suffix=True)
    browser.submit(Forms(page).one("/quote", suffix=True), dict(quote, revision="2", total_minor="12500", source_ref="synthetic-quote-2"))
    page = browser.page(request_path)
    current = Forms(page).one("/accept", suffix=True)
    # Use the CURRENT aggregate version, so refusal tests the obsolete quote,
    # not merely stale optimistic concurrency.
    browser.submit(old_accept, {"expected_version": current["fields"]["expected_version"],
                   "_csrf_token": current["fields"]["_csrf_token"], "evidence_ref": "obsolete"}, expected=409)
    checks["obsolete_quote_denied"] = True
    browser.submit(current, {"evidence_ref": "synthetic-buyer-acceptance"})
    page = browser.page(request_path)
    browser.submit(Forms(page).one("/fulfill", suffix=True), {"evidence_ref": "synthetic-delivery"})
    page = browser.page(request_path)
    require("fulfilled" in page and "Frozen accepted quote" in page and "12500" in page,
            "fulfilled frozen quote absent")
    checks["http_lifecycle"] = True
    current_csrf = Forms(page).one("/logout")["fields"]["_csrf_token"]
    original["_csrf_token"] = current_csrf
    browser.submit({"action": create["action"], "fields": {}}, original)
    # Offline inspection below establishes exact retry was inert at version 6.
    return request_path, original


def acceptance(archive: Path, revision: str, receipts: Path) -> dict:
    env = database_environment(dict(os.environ))
    for executable in ("createdb", "dropdb", "pg_dump", "pg_restore", "openssl"):
        require(shutil.which(executable) is not None, f"required tool unavailable: {executable}")
    artifact_sha256 = digest(archive)
    checks: dict[str, bool] = {}
    receipts.mkdir(parents=True, exist_ok=True)
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix="bizkit-procurement-") as directory:
        work = Path(directory)
        root = unpack(archive, work, revision)
        checks["packaged_identity"] = True
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        token = secrets.token_urlsafe(48)
        database = "procurement_acceptance_" + secrets.token_hex(6)
        env.update(EVENTSTORE_DATABASE=database, PROCUREMENT_DATA_DIR=str(work / "data"),
                   PROCUREMENT_SIGNING_SEED_HEX=secrets.token_hex(32),
                   PROCUREMENT_LOGIN_SHA256=hashlib.sha256(token.encode()).hexdigest(),
                   PROCUREMENT_SECRET_KEY_BASE=secrets.token_hex(64),
                   PROCUREMENT_CHAPTER="acceptance-chapter", PROCUREMENT_COOPERATIVE="acceptance-coop",
                   PROCUREMENT_OPERATOR="acceptance-operator", PROCUREMENT_KEY_ID="acceptance-key",
                   PROCUREMENT_GRANT_VERSION="1", PROCUREMENT_PORT=str(port),
                   PROCUREMENT_GOVERNANCE_SEED_HEX=secrets.token_hex(32))
        harness = Harness(root, work, receipts, env)
        tls = None
        try:
            harness.create_database(database)
            harness.run([harness.executable, "eval", "ProcurementHost.ReleaseTasks.migrate()"], label="migrate")
            checks["migration"] = True
            harness.fixture("seed")
            certificate, key = work / "tls.crt", work / "tls.key"
            harness.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                         "-keyout", str(key), "-out", str(certificate), "-subj", "/CN=127.0.0.1",
                         "-addext", "subjectAltName=IP:127.0.0.1"], label="test-certificate")
            harness.start()
            tls = proxy(port, certificate, key)
            browser = Browser(f"https://127.0.0.1:{tls.server_address[1]}", certificate)
            path, retry = lifecycle(browser, token, checks)
            harness.stop()
            before = harness.fixture("inspect")
            expected = {"phase": "fulfilled", "version": 6, "command_count": 6,
                        "quote_revision": 2, "quote_total_minor": 12500, "payment_evidence_count": 0}
            require(before["requests"] == [expected], "lifecycle/retry produced unexpected persistent state")
            checks["exact_retry_inert"] = True
            harness.start()
            require("fulfilled" in browser.page(path), "HTTP record missing after cold restart")
            harness.stop()
            require(harness.fixture("inspect") == before, "cold restart changed canonical history")
            checks["restart_replay"] = True
            harness.fixture("revoke")
            revoked = harness.fixture("inspect")
            require(revoked["grant_active"] is False, "revocation did not persist")
            harness.start()
            # Write first: rejection is tested with the pre-revocation cookie,
            # not merely after a prior denied read has cleared the session.
            browser.denied(path + "/request", retry)
            browser.denied(path)
            checks["revoked_session_denied"] = True
            harness.stop()
            require(harness.fixture("inspect") == revoked, "revoked write changed history")
            checks["revoked_write_inert"] = True
            backup = work / "synthetic.dump"
            harness.run(["pg_dump", "--format=custom", "--file=" + str(backup), "--dbname=" + database], label="backup")
            restored = database + "_restore"
            harness.create_database(restored)
            harness.run(["pg_restore", "--exit-on-error", "--no-owner", "--no-privileges",
                         "--dbname=" + restored, str(backup)], label="restore")
            env.update(EVENTSTORE_DATABASE=restored, PROCUREMENT_DATA_DIR=str(work / "restored-data"))
            require(harness.fixture("inspect") == revoked, "restored head/hash/replayed records differ")
            checks["backup_restore_equal"] = True
            harness.start()
            denied = Forms(browser.page("/login")).one("/login")
            browser.submit(denied, {"token": token}, expected=401)
            browser.denied(path)
            checks["restored_revocation_denied"] = True
            harness.stop()
            receipt = {"kind": "procurement-packaged-acceptance-v1", "revision": revision,
                       "artifact_sha256": artifact_sha256, "checks": checks,
                       "trust": "unsigned-runner-observation", "restored_ledger": revoked,
                       "scope": "synthetic loopback HTTPS/SQL; not target-host or graphical-browser acceptance"}
            validate_receipt(receipt, revision, artifact_sha256)
        finally:
            if tls is not None:
                tls.shutdown()
                tls.server_close()
            harness.cleanup()
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--receipts", type=Path, required=True)
    args = parser.parse_args()
    destination = args.receipts.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    receipt_path = destination / "receipt.json"
    receipt_path.unlink(missing_ok=True)  # A previous success never survives a failed rerun.
    receipt = acceptance(args.archive.resolve(), args.revision, destination)
    receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    print(json.dumps(receipt, sort_keys=True))


if __name__ == "__main__":
    main()
