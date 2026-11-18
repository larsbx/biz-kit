"""Test-only crash barrier; never part of the receiver's request protocol.

Execute the actual request handler, announce its committed successful result
on stderr, and withhold the ordinary response until the harness SIGKILLs us.
"""

import json
import os
import signal
import sys

import receiver


os.umask(0o077)
mode = sys.argv[2] if len(sys.argv) == 3 else "commit"
if mode == "lock":
    original_connect = receiver._connect

    def traced_connect(path):
        connection = original_connect(path)

        def trace(statement):
            if statement == "BEGIN IMMEDIATE":
                print("LOCK_REQUEST", file=sys.stderr, flush=True)

        connection.set_trace_callback(trace)
        return connection

    receiver._connect = traced_connect
elif mode != "commit":
    raise SystemExit(2)

response, status = receiver.handle_request(
    sys.argv[1], sys.stdin.buffer.read(receiver.MAX_REQUEST_BYTES + 1))
if mode == "lock":
    print(json.dumps(response), flush=True)
    raise SystemExit(status)
if status != 0 or response.get("disposition") != "created":
    print(json.dumps(response), flush=True)
    raise SystemExit(status or 2)
print("COMMITTED", file=sys.stderr, flush=True)
while True:
    signal.pause()
