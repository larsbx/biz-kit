"""The fixed trusted local workload. No arbitrary command or descendants.

One bounded SHA256 calculation produces a 65-byte artifact. Afterwards this
same process waits without an IPC listener until its deadline or termination.
It cannot turn output or process state into business authority.
"""

from datetime import datetime, timezone
import hashlib
import os
from pathlib import Path
import signal
import sys
import time


def _before_registration(_row):
    """No-op child boundary overridden only by isolated test wrappers."""


def calculate_result(effect_id, plan_digest):
    seed = hashlib.sha256(("bizkit.fixed-local-worker.v1\n" + effect_id + "\n" + plan_digest + "\n").encode()).digest()
    result = hashlib.sha256()
    for counter in range(4096):
        result.update(seed + counter.to_bytes(4, "big"))
    return result.hexdigest()


def _register(p, db, row, identity):
    connection = p._connect(db)
    try:
        connection.execute("BEGIN IMMEDIATE")
        p._check_store(connection, row["store_id"])
        current = p._get_row(connection, row["effect_id"])
        if (current is None or current["launch_nonce"] != row["launch_nonce"]
                or current["pid"] is not None or current["termination_verified"]):
            raise p.Rejected("spawn_unconfirmed")
        # Registration records even a fenced child so cleanup can identify it.
        # A separate locked check below refuses its actual workload.
        connection.execute("UPDATE local_workers SET boot_id=?,pid=?,start_ticks=? WHERE effect_id=?",
                           (identity["boot_id"], identity["pid"], identity["start_ticks"], row["effect_id"]))
        connection.execute("COMMIT")
    finally:
        p.base._close(connection)


def _work(p, db, row):
    connection = p._connect(db)
    try:
        connection.execute("BEGIN IMMEDIATE")
        p._check_store(connection, row["store_id"])
        current = p._get_row(connection, row["effect_id"])
        if (current["fenced"] or p._expired(current) or current["work_count"]
                or current["launch_nonce"] != row["launch_nonce"]
                or current["pid"] != os.getpid()):
            connection.execute("COMMIT")
            return
        digest = calculate_result(row["effect_id"], row["plan_digest"])
        descriptor = os.open(p._artifact_path(db, row), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            with os.fdopen(descriptor, "wb", closefd=False) as artifact:
                artifact.write((digest + "\n").encode("ascii"))
                artifact.flush()
                os.fsync(descriptor)
        finally:
            os.close(descriptor)
        connection.execute("UPDATE local_workers SET work_count=1,result_digest=? WHERE effect_id=?",
                           (digest, row["effect_id"]))
        connection.execute("COMMIT")
    finally:
        p.base._close(connection)


def _wait(until):
    while time.monotonic() < until:
        time.sleep(min(0.2, max(0, until - time.monotonic())))


def main(argv=None):
    # This alarm starts before SQLite access or test registration
    # barriers. SIGALRM's default action stops this fixed no-descendant process.
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.setitimer(signal.ITIMER_REAL, 30.0)
    started = time.monotonic()
    os.umask(0o077)
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import provider as p

    values = sys.argv[1:] if argv is None else argv
    if len(values) != 3:
        return 2
    db, effect, nonce = values
    try:
        p._platform()
        row = p._read_row(db, effect)
        if row is None or row["launch_nonce"] != nonce or row["pid"] is not None:
            return 2
        remaining = (datetime.fromisoformat(row["execution_deadline"].replace("Z", "+00:00"))
                     - datetime.now(timezone.utc)).total_seconds()
        remaining = min(30.0 - (time.monotonic() - started), remaining)
        if remaining <= 0:
            return 1
        signal.setitimer(signal.ITIMER_REAL, remaining)
        until = time.monotonic() + remaining
        identity = p._identity()
        _before_registration(row)
        _register(p, db, row, identity)
        _work(p, db, row)
        _wait(until)
        return 0
    except (OSError, ValueError, p.Rejected, p.base.Rejected):
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
