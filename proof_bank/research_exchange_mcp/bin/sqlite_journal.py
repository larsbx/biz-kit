"""Private framed port for the MCP server, never a contributor endpoint."""
import os
from pathlib import Path
import sqlite3
import stat
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "research_exchange"))
from adapter_pilot.common import PilotError
from adapter_pilot.store import Store

MAX_FRAME = 24 * 1024 * 1024
HEADER = struct.Struct(">QQ")


def run(path):
    os.umask(0o077)
    path = Path(path)
    if not path.is_absolute() or not path.parent.is_dir():
        raise ValueError("the journal requires an absolute path in an operator-owned directory")
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    with os.fdopen(fd, "rb") as file:
        info = os.fstat(file.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o077 or info.st_nlink != 1):
            raise ValueError("the journal must be private to its operator")
    store = Store(path)
    with store.connection() as conn:
        if conn.execute("PRAGMA journal_mode=WAL").fetchone()[0] != "wal":
            raise ValueError("WAL is required")
    with store.transaction() as conn:
        conn.execute("""CREATE TABLE IF NOT EXISTS mcp_journal_v1 (
            singleton INTEGER PRIMARY KEY CHECK(singleton=1),
            epoch INTEGER NOT NULL, version INTEGER NOT NULL,
            snapshot BLOB NOT NULL CHECK(length(snapshot) <= 25165824)
        )""")
        conn.execute("INSERT OR IGNORE INTO mcp_journal_v1 VALUES(1,0,0,X'')")

    source, sink = sys.stdin.buffer, sys.stdout.buffer
    while size := source.read(4):
        length = int.from_bytes(size, "big")
        if len(size) != 4 or not 1 <= length <= MAX_FRAME:
            raise ValueError("invalid frame size")
        frame = source.read(length)
        if len(frame) != length:
            raise EOFError("incomplete frame")
        with store.transaction() as conn:
            row = conn.execute("SELECT epoch,version FROM mcp_journal_v1").fetchone()
            epoch, version = row
            if frame == b"B":
                conn.execute("UPDATE mcp_journal_v1 SET epoch=epoch+1 WHERE singleton=1")
                snapshot = conn.execute("SELECT snapshot FROM mcp_journal_v1").fetchone()[0]
                reply = b"O" + HEADER.pack(epoch + 1, version) + snapshot
            elif len(frame) >= 17 and frame[1:17] != HEADER.pack(epoch, version):
                reply = b"F"
            elif frame[:1] == b"R" and len(frame) == 17:
                reply = b"O"
            elif frame[:1] == b"W" and len(frame) > 17:
                changed = conn.execute(
                    "UPDATE mcp_journal_v1 SET version=version+1,snapshot=? "
                    "WHERE singleton=1 AND epoch=? AND version=?", (frame[17:], epoch, version)
                )
                reply = b"O" if changed.rowcount == 1 else b"F"
            else:
                raise ValueError("invalid operation")
        # In particular, acknowledge writes only after SQLite commits.
        sink.write(len(reply).to_bytes(4, "big") + reply)
        sink.flush()


if __name__ == "__main__":
    try:
        run(sys.argv[1])
    except (OSError, sqlite3.Error, PilotError, ValueError, EOFError) as exc:
        sys.exit(f"MCP SQLite journal stopped ({type(exc).__name__})")
