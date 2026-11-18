"""Local WebKitDriver sessions for packaged Tauri acceptance."""
from contextlib import contextmanager
import json
import os
import signal
import socket
import subprocess
import time
import urllib.error
import urllib.request


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def until(check, description):
    end = time.monotonic() + 20
    while time.monotonic() < end:
        result = check()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError(f"Timed out: {description}")


@contextmanager
def native_session(binary, env, log, timeout=60):
    port, native_port = free_port(), free_port()
    # Ignore shell proxy variables for the local WebDriver connection.
    http = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def request(method, path, payload=None, timeout=30):
        data = None if payload is None else json.dumps(payload).encode()
        req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data,
                                     headers={"Content-Type": "application/json"}, method=method)
        try:
            with http.open(req, timeout=timeout) as reply:
                value = json.load(reply).get("value")
        except urllib.error.HTTPError as error:
            raise AssertionError(error.read().decode()) from error
        if isinstance(value, dict) and "error" in value:
            raise AssertionError(value)
        return value

    driver = subprocess.Popen(["tauri-driver", "--port", str(port), "--native-port", str(native_port)],
                              env=env, stdout=log, stderr=log, start_new_session=True)
    session = None
    try:
        def ready():
            if driver.poll() is not None:
                raise RuntimeError("tauri-driver exited before readiness")
            try:
                for endpoint in (port, native_port):
                    with socket.create_connection(("127.0.0.1", endpoint), timeout=0.1):
                        pass
                return True
            except OSError:
                return False

        until(ready, "tauri-driver")
        print("Native acceptance: creating Tauri/WebKit session", flush=True)
        session = request("POST", "/session", {"capabilities": {"alwaysMatch": {
            "tauri:options": {"application": str(binary)},
        }}}, timeout=timeout)["sessionId"]
        print("Native acceptance: session ready", flush=True)
        yield request, f"/session/{session}"
    finally:
        try:
            if session:
                request("DELETE", f"/session/{session}")
        finally:
            # Also stop WebKit/app descendants after a failed handshake.
            try:
                os.killpg(driver.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                driver.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(driver.pid, signal.SIGKILL)
                driver.wait()
