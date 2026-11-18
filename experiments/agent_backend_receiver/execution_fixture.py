"""Private stdio driver for the fixed Linux acceptance workload."""

import argparse
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

import receiver


def send(message):
    print(json.dumps(message, separators=(",", ":")), flush=True)


def barrier(chosen, boundary, backend_id):
    if chosen == boundary:
        send({"phase": boundary, "backend_id": backend_id})
        # The test kills this receiver from another process. Timing out never
        # turns the injected fault into an ordinary success response.
        time.sleep(8)
        raise SystemExit(2)


def observe(directory):
    result = {"workload": "unknown", "starts": 0, "cancel_received": False}
    if directory is None or not (directory / "started").exists():
        return result
    with (directory / "started").open("rb") as witness:
        workload = "stopped"
        try:
            # A fresh open description conflicts only while the original
            # worker (or its starting receiver) retains the inherited lock.
            fcntl.flock(witness, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            workload = "running"
        progress = witness.read(3)
    if not progress:
        return result
    return {"workload": workload, "starts": progress.count(b"S"),
            "cancel_received": progress == b"SC"}


def stop(directory):
    if directory is None:
        return
    try:
        fd = os.open(directory / "stop", os.O_WRONLY | os.O_NONBLOCK)
    except OSError as error:
        if error.errno in (errno.ENOENT, errno.ENXIO):
            return
        raise
    try:
        os.write(fd, b"C")
    finally:
        os.close(fd)


def spawn(directory, worker, start_by):
    directory.mkdir(mode=0o700)
    os.mkfifo(directory / "stop", 0o600)
    with (directory / "started").open("x+b", buffering=0) as witness:
        fcntl.flock(witness, fcntl.LOCK_EX)
        # Open once without blocking, then hand the worker a blocking read
        # description. Its own writer endpoint keeps the FIFO live after a
        # receiver crash. A later receiver can open an independent writer.
        stop_fd = os.open(directory / "stop", os.O_RDWR | os.O_NONBLOCK)
        try:
            os.set_blocking(stop_fd, True)
            fd = witness.fileno()
            process = subprocess.Popen(
                [worker, str(fd), str(stop_fd), str(start_by)],
                cwd=directory, env={}, pass_fds=(fd, stop_fd),
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, start_new_session=True,
            )
        finally:
            os.close(stop_fd)
        until = time.monotonic() + 2
        try:
            while os.pread(fd, 2, 0) != b"S":
                if process.poll() is not None or time.monotonic() >= until:
                    raise RuntimeError("fixture worker did not start")
                time.sleep(0.01)
            os.fsync(fd)
        except BaseException:
            process.kill()
            process.wait(timeout=2)
            raise


def lock(store):
    until = time.monotonic() + 3
    while True:
        try:
            fcntl.flock(store, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            if time.monotonic() >= until:
                raise
            time.sleep(0.01)


def execute(args, raw, request, permit):
    root = Path(args.db).parent
    with (root / "fixture.lock").open("ab") as mutex:
        lock(mutex)
        operation = request["operation"]
        if operation == "create":
            start_by = permit["start_by_us"]
            if start_by <= time.time_ns() // 1000:
                return {"error": "start_permit_expired"}
            with open(args.worker, "rb") as program:
                if hashlib.file_digest(program, "sha256").hexdigest() != args.worker_sha256:
                    return {"error": "fixture_worker_digest_changed"}
        receipt, status = receiver.handle_request(args.db, raw)
        if status != 0:
            return {"receipt": receipt}
        backend_id = receipt["backend_id"]
        directory = root / backend_id if backend_id else None
        if receipt["disposition"] == "created":
            barrier(args.fault, "reserved", backend_id)
            if start_by > time.time_ns() // 1000:
                spawn(directory, args.worker, start_by)
                barrier(args.fault, "started", backend_id)
        elif operation == "fence":
            barrier(args.fault, "fenced", backend_id)
            stop(directory)
        return {"receipt": receipt, **observe(directory)}


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", required=True)
    parser.add_argument("--worker", required=True)
    parser.add_argument("--worker-sha256", required=True)
    parser.add_argument("--fault", choices=("none", "reserved", "started", "fenced"), default="none")
    args = parser.parse_args()
    raw = sys.stdin.buffer.readline(receiver.MAX_REQUEST_BYTES + 1)
    request = receiver._validate(receiver._decode(raw))
    send({"phase": "waiting"})
    line = sys.stdin.buffer.readline(128)
    if not line:
        return
    permit = json.loads(line)
    send({"phase": "reply", **execute(args, raw, request, permit)})


if __name__ == "__main__":
    main()
