"""Loopback-only HTTP acceptance service for disposable fixture credits."""
from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import re
import socket
import sqlite3
import time

from .checker import ControlledChecker
from .common import MAX_BODY, PilotError, canonical, identifier, parse_json
from .store import PreparedVerification, Reply, Store


class Service:
    def __init__(self, store: Store, checker: ControlledChecker, *,
                 failpoint: str | None = None, failpoint_request_id: str | None = None,
                 pause_after_verification: Path | None = None,
                 pause_request_id: str | None = None):
        if failpoint not in (None, "before_commit", "after_commit"):
            raise ValueError("unknown failpoint")
        if (failpoint is None) != (failpoint_request_id is None):
            raise ValueError("failpoint and its request ID must be configured together")
        if (pause_after_verification is None) != (pause_request_id is None):
            raise ValueError("pause path and request ID must be configured together")
        for request_id in (failpoint_request_id, pause_request_id):
            if request_id is not None:
                identifier(request_id)
        self.store, self.checker = store, checker
        self.failpoint, self.failpoint_request_id = failpoint, failpoint_request_id
        self.pause_path = Path(pause_after_verification) if pause_after_verification else None
        self.pause_request_id = pause_request_id

    def _pause(self, prepared: PreparedVerification) -> None:
        if self.pause_path is None or prepared.request_id != self.pause_request_id:
            return
        ready = Path(str(self.pause_path) + ".ready")
        release = Path(str(self.pause_path) + ".release")
        ready.write_bytes(canonical({"pid": os.getpid(), "request_id": prepared.request_id,
                                    "version": prepared.version}))
        deadline = time.monotonic() + 20
        while not release.is_file():
            if time.monotonic() >= deadline:
                raise PilotError(503, "test_pause_timeout")
            time.sleep(0.01)

    def verify(self, token: str, slot_id: str, body: dict) -> Reply:
        prepared = self.store.prepare_verification(token, slot_id, body)
        if isinstance(prepared, Reply):
            return prepared
        try:
            decision = self.checker.check(prepared.profile, prepared.artifact)
        except PilotError as exc:
            return self.store.record_verification_failure(prepared, exc)
        self._pause(prepared)

        def before_commit():
            if self.failpoint == "before_commit" and prepared.request_id == self.failpoint_request_id:
                os._exit(86)

        def after_commit():
            if self.failpoint == "after_commit" and prepared.request_id == self.failpoint_request_id:
                os._exit(87)

        return self.store.commit_verification(prepared, decision,
                                               before_commit=before_commit, after_commit=after_commit)


def make_handler(service: Service):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"
        server_version = "ResearchExchangeLocalPilot/1"
        sys_version = ""

        def log_message(self, _format, *args):
            # Authentication tokens, bodies and uncontrolled URL text do not
            # belong in request logs or checker receipts.
            return

        def _send(self, reply: Reply):
            payload = canonical(reply.body)
            self.send_response(reply.status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)

        def _token(self) -> str:
            headers = self.headers.get_all("Authorization", [])
            if len(headers) != 1 or not headers[0].startswith("Bearer "):
                raise PilotError(401, "unauthorized")
            return headers[0][7:]

        def _body(self) -> dict:
            if self.headers.get_all("Transfer-Encoding", []):
                raise PilotError(400, "invalid_framing")
            lengths = self.headers.get_all("Content-Length", [])
            if len(lengths) != 1 or re.fullmatch(r"[0-9]{1,10}", lengths[0]) is None:
                raise PilotError(400, "invalid_framing")
            length = int(lengths[0])
            if length > MAX_BODY:
                raise PilotError(413, "body_too_large")
            types = self.headers.get_all("Content-Type", [])
            if types != ["application/json"]:
                raise PilotError(415, "invalid_content_type")
            self.connection.settimeout(5)
            data = self.rfile.read(length)
            if len(data) != length:
                raise PilotError(400, "invalid_framing")
            return parse_json(data)

        def _dispatch(self, post: bool):
            try:
                path = self.path
                worker = re.fullmatch(r"/v1/slots/([A-Za-z0-9_.-]{1,80})(?:/(lease|submit))?", path)
                verifier = re.fullmatch(r"/internal/slots/([A-Za-z0-9_.-]{1,80})/verify", path)
                if post and worker and worker[2]:
                    token, body = self._token(), self._body()
                    operation = service.store.lease if worker[2] == "lease" else service.store.submit
                    reply = operation(token, worker[1], body)
                elif post and verifier:
                    reply = service.verify(self._token(), verifier[1], self._body())
                elif not post and worker and worker[2] is None:
                    if self.headers.get_all("Transfer-Encoding", []) or self.headers.get("Content-Length", "0") != "0":
                        raise PilotError(400, "invalid_framing")
                    reply = service.store.status(self._token(), worker[1])
                else:
                    raise PilotError(404, "unknown_route")
                self._send(reply)
            except PilotError as exc:
                self._send(Reply(exc.status, {"error": exc.code}))
            except (sqlite3.Error, OSError, ValueError, TypeError, KeyError, RecursionError):
                self._send(Reply(503, {"error": "service_unavailable"}))

        def do_GET(self):
            self._dispatch(False)

        def do_POST(self):
            self._dispatch(True)

    return Handler


def make_server(service: Service, port: int = 0, host: str = "127.0.0.1") -> ThreadingHTTPServer:
    if host != "127.0.0.1":
        raise ValueError("this pilot can only listen on literal IPv4 loopback")
    if type(port) is not int or not 0 <= port <= 65535:
        raise ValueError("invalid port")
    server = ThreadingHTTPServer((host, port), make_handler(service))
    server.daemon_threads = True
    return server


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, required=True)
    parser.add_argument("--lean-root", type=Path, required=True)
    parser.add_argument("--package-root", type=Path)
    parser.add_argument("--application-path-adapter", type=Path)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--ready-file", type=Path, required=True)
    parser.add_argument("--failpoint", choices=("before_commit", "after_commit"))
    parser.add_argument("--failpoint-request-id")
    parser.add_argument("--pause-after-verification", type=Path)
    parser.add_argument("--pause-request-id")
    args = parser.parse_args()
    store = Store(args.db)
    store.initialize()
    checker = ControlledChecker(args.lean_root, args.package_root, args.application_path_adapter)
    service = Service(store, checker, failpoint=args.failpoint,
                      failpoint_request_id=args.failpoint_request_id,
                      pause_after_verification=args.pause_after_verification,
                      pause_request_id=args.pause_request_id)
    server = make_server(service, args.port, args.host)
    ready = {"port": server.server_address[1], "host": "127.0.0.1", "pid": os.getpid(),
             "scope": "local-fixture-credits-only"}
    args.ready_file.parent.mkdir(parents=True, exist_ok=True)
    temp = args.ready_file.with_name(args.ready_file.name + ".tmp")
    temp.write_bytes(canonical(ready))
    temp.chmod(0o600)
    temp.replace(args.ready_file)
    try:
        server.serve_forever(poll_interval=0.1)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

