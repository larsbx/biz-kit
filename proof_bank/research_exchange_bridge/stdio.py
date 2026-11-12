#!/usr/bin/env python3
"""Private local bridge RPC; the public MCP transport remains the Elixir server."""
from __future__ import annotations

import argparse
from pathlib import Path
import sys
import threading

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from research_exchange_bridge.common import (BridgeError, MAX_FRAME, SCHEMA, canonical,
                                             exact, integer, load_config, loads, receipt_key)
from research_exchange_bridge.store import Store


def serve(config, source, destination):
    store = Store(config["database"], receipt_key(config["receipt_key_base64"]))
    store.initialize()
    stop = threading.Event()

    def worker():
        while not stop.is_set():
            try:
                for job_id in store.pending(include_source=False):
                    if stop.is_set():
                        return
                    failpoint = config.get("test_failpoint") if config.get("test_job_id", job_id) == job_id else None
                    pause_path = config.get("test_pause_after_check") if config.get("test_pause_job_id", job_id) == job_id else None
                    store.execute_one(job_id, config["lean_root"], failpoint=failpoint, pause_path=pause_path)
            except BridgeError:
                # Operational failures do not turn into mathematical acceptance.
                # Pending durable work remains available for a later process.
                pass
            stop.wait(config.get("poll_interval_ms", 200) / 1000)

    thread = None
    if config.get("worker_enabled", True):
        thread = threading.Thread(target=worker, daemon=True, name="reviewed-export-worker")
        thread.start()
    try:
        while True:
            line = source.readline(MAX_FRAME + 2)
            if not line:
                return 0
            request_id = None
            try:
                if len(line) > MAX_FRAME + 1 or not line.endswith(b"\n"):
                    return 2
                request = loads(line)
                if type(request) is not dict or request.get("schema") != SCHEMA or not integer(request.get("id")):
                    return 2
                request_id = request["id"]
                if request.get("op") == "authenticate":
                    exact(request, ("schema", "id", "op", "token"))
                    value = store.authenticate(request["token"])
                elif request.get("op") == "call":
                    exact(request, ("schema", "id", "op", "token", "tool", "arguments"))
                    value = store.call(request["token"], request["tool"], request["arguments"])
                else:
                    raise BridgeError("invalid_arguments")
                response = {"schema": SCHEMA, "id": request_id, "ok": True, "result": value}
            except BridgeError as error:
                if request_id is None:
                    return 2
                response = {"schema": SCHEMA, "id": request_id, "ok": False, "error": error.code}
            encoded = canonical(response)
            if len(encoded) > MAX_FRAME:
                return 2
            destination.write(encoded + b"\n")
            destination.flush()
    finally:
        stop.set()
        if thread:
            thread.join(timeout=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    args = parser.parse_args()
    try:
        return serve(load_config(args.config), sys.stdin.buffer, sys.stdout.buffer)
    except (BridgeError, OSError, ValueError):
        # Never print the operator configuration, tokens, MAC key or traceback.
        print("DURABLE_BRIDGE_STARTUP_REFUSED", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
