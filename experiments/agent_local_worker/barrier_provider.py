"""Test-only pauses around the real provider and fixed worker implementation.

Manager CLI: barrier_provider.py DATABASE [after_work|before_spawn|before_registration]
reads the ordinary create JSON to EOF. The fixed worker wrapper is selected
only inside this fixture; no barrier command is added to the provider protocol.
"""

import array
import json
import os
from pathlib import Path
import signal
import socket
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))


def wait_until(predicate, timeout=10):
    end = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() >= end:
            raise TimeoutError("test barrier did not receive its bounded release")
        time.sleep(0.01)


def registration_paths(database, row):
    prefix = Path(database).parent / ("barrier-" + row["launch_nonce"])
    return Path(str(prefix) + ".ready"), Path(str(prefix) + ".release")


def worker_wrapper(arguments):
    import worker

    database = arguments[0]

    def before_registration(row):
        ready, release = registration_paths(database, row)
        try:
            ready.write_text(str(os.getpid()) + "\n")
            wait_until(release.exists)
        finally:
            ready.unlink(missing_ok=True)
            release.unlink(missing_ok=True)

    worker._before_registration = before_registration
    return worker.main(arguments)


def manager(database, mode):
    import provider

    if mode not in {"after_work", "before_spawn", "before_registration"}:
        raise SystemExit("unknown test-only provider barrier")

    resumed = False

    def release(signum, frame):
        nonlocal resumed
        resumed = True

    signal.signal(signal.SIGUSR1, release)

    def pause(marker):
        print(marker, file=sys.stderr, flush=True)
        wait_until(lambda: resumed)

    def after_reservation(row):
        if mode == "before_spawn":
            pause("RESERVED")

    def after_spawn(child, row):
        if mode != "before_registration":
            return
        descriptor = os.pidfd_open(child.pid, 0)
        try:
            observer = os.environ.get("BIZKIT_TEST_OBSERVER_FD")
            if observer is not None:
                with socket.socket(fileno=os.dup(int(observer))) as channel:
                    channel.sendmsg(
                        [json.dumps({"pid": child.pid}).encode()],
                        [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [descriptor]))],
                    )
            ready, released = registration_paths(database, row)
            wait_until(ready.exists)
            if int(ready.read_text()) != child.pid:
                raise AssertionError("registration barrier identified the wrong child")
            pause("UNREGISTERED")
            released.write_text("released\n")
        finally:
            os.close(descriptor)

    def before_response(response):
        if mode == "after_work":
            if (response.get("execution_started") is not True
                    or response.get("work_count") != 1
                    or not response.get("result_digest")):
                raise AssertionError("ordinary provider response has no committed fixed work")
            pause("WORKED")

    provider._after_reservation = after_reservation
    provider._after_spawn = after_spawn
    provider._before_response = before_response
    if mode == "before_registration":
        provider.WORKER = str(Path(__file__).resolve())
    response, status = provider.handle_request(
        database, sys.stdin.buffer.read(provider.MAX_REQUEST_BYTES + 1))
    print(json.dumps(response), flush=True)
    return status


if __name__ == "__main__":
    os.umask(0o077)
    if len(sys.argv) == 4 and sys.argv[2].startswith("agent-run:"):
        raise SystemExit(worker_wrapper(sys.argv[1:]))
    if len(sys.argv) not in (2, 3):
        raise SystemExit("expected DATABASE and optional barrier mode")
    raise SystemExit(manager(sys.argv[1], sys.argv[2] if len(sys.argv) == 3 else "after_work"))
