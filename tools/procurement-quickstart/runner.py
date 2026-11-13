#!/usr/bin/env python3
"""Run the existing formal and packaged-host acceptance in a disposable container."""
from __future__ import annotations
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import subprocess
import sys
import time

from evidence import STAGES, TRUST, packaged, require, write_manifest

SOURCE = Path("/source")
OUTPUT = Path("/evidence")
WORK = Path("/work")


def command(args: list[str], name: str, env: dict[str, str], timeout: int = 1200) -> str:
    path = OUTPUT / (name + ".log")
    path.parent.mkdir(parents=True, exist_ok=True)
    print("RUN " + name, flush=True)
    with path.open("w") as stream:
        result = subprocess.run(args, cwd=SOURCE, env=env, stdout=stream,
                                stderr=subprocess.STDOUT, timeout=timeout, check=False)
    require(result.returncode == 0, f"{name} exited {result.returncode}; see {name}.log")
    return path.read_text(errors="replace")


def interrupted(signum, _frame):
    raise RuntimeError(f"interrupted by signal {signum}")


def run() -> int:
    os.umask(0o077)
    OUTPUT.mkdir(exist_ok=True)
    WORK.mkdir(exist_ok=True)
    # Never reuse a previous run or its success receipt.
    require(not any(OUTPUT.iterdir()), "evidence directory must be fresh")
    revision = os.environ.get("SOURCE_REVISION", "")
    image = os.environ.get("QUICKSTART_IMAGE_ID", "")
    result = {"kind": "procurement-quickstart-v1", "trust": TRUST,
              "revision": revision, "image_id": image, "status": "failed",
              "started_at_unix": int(time.time()),
              "scope": "disposable synthetic execution; not target-host, graphical-browser or production acceptance",
              "stages": {stage: None for stage in sorted(STAGES)}}
    env = dict(os.environ, PROCUREMENT_ENABLED="false", RELEASE_DISTRIBUTION="none",
               PYTHONDONTWRITEBYTECODE="1", ERL_FLAGS="+S 4:4")
    pgdata = WORK / "postgres"
    current = "preflight"
    database_started = False
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, interrupted)
    try:
        require(bool(re.fullmatch(r"[0-9a-f]{40}", revision)), "full source revision required")
        require(bool(re.fullmatch(r"sha256:[0-9a-f]{64}", image)), "image ID required")
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=SOURCE, text=True).strip()
        require(head == revision, "source snapshot revision mismatch")
        dirty = subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=all"], cwd=SOURCE, text=True)
        require(not dirty, "source snapshot is dirty")
        command(["bash", "-euo", "pipefail", "-c",
                 "elixir --version; lean --version; quint --version; rustc --version; "
                 "cargo --version; node --version; python3 --version; pg_dump --version; "
                 "pg_restore --version; cat /opt/downloads.sha256; dpkg-query -W"], "toolchain", env)
        result["stages"][current] = True

        current = "formal"
        for model in ("Workflow", "Admission"):
            text = command(["lean", f"proofs/procurement_mvp/{model}.lean"], f"formal/{model}", env)
            require("sorryAx" not in text, "Lean replay reported sorryAx")
        for model in ("workflow", "admission"):
            path = f"proofs/procurement_mvp/{model}.qnt"
            command(["quint", "typecheck", path], f"formal/{model}-typecheck", env)
            command(["quint", "test", path, "--seed=20261108"], f"formal/{model}-tests", env)
            command(["quint", "run", path, "--invariant=invariant", "--max-steps=24",
                     "--max-samples=2000", "--seed=20261108"], f"formal/{model}-run", env)
        result["stages"][current] = True

        current = "database"
        password = secrets.token_hex(32)
        password_file = WORK / "postgres-password"
        password_file.write_text(password + "\n")
        (WORK / "socket").mkdir()
        command(["initdb", "-D", str(pgdata), "--username=postgres", "--auth-local=trust",
                 "--auth-host=scram-sha-256", "--pwfile=" + str(password_file)], "database", env)
        password_file.unlink()
        command(["pg_ctl", "-D", str(pgdata), "-l", str(OUTPUT / "postgres.log"),
                 "-o", "-h 127.0.0.1 -p 5432 -k /work/socket", "-w", "start"], "database-start", env)
        database_started = True
        result["stages"][current] = True
        env.update(EVENTSTORE_USERNAME="postgres", EVENTSTORE_PASSWORD=password,
                   EVENTSTORE_HOST="127.0.0.1", EVENTSTORE_PORT="5432",
                   PROCUREMENT_RELEASE_ACCEPTANCE="disposable-local-postgres",
                   PROCUREMENT_RECEIPTS=str(OUTPUT / "host"), SOURCE_REVISION=revision)
        current = "runtime"
        command(["bash", "scripts/test-procurement-host.sh"], "runtime", env, timeout=2400)
        result["stages"][current] = True
        current = "receipt"
        packaged(OUTPUT, revision)
        result["stages"][current] = True
    except Exception as error:
        result["stages"][current] = False
        result["error"] = str(error)
        print("FAILED: " + str(error), file=sys.stderr, flush=True)
    finally:
        # Cleanup remains required even when a stage fails. The host removes this
        # container afterwards; no host database or persistent volume was mounted.
        for sig in (signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, signal.SIG_IGN)
        try:
            if database_started or (pgdata / "postmaster.pid").exists():
                command(["pg_ctl", "-D", str(pgdata), "-m", "fast", "-w", "stop"], "cleanup", env)
            else:
                (OUTPUT / "cleanup.log").write_text("No PostgreSQL process started.\n")
            result["stages"]["cleanup"] = True
        except Exception as error:
            result["stages"]["cleanup"] = False
            result["cleanup_error"] = str(error)
        result["status"] = "passed" if all(value is True for value in result["stages"].values()) else "failed"
        result["finished_at_unix"] = int(time.time())
        (OUTPUT / "result.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        write_manifest(OUTPUT)
    print(json.dumps(result, sort_keys=True), flush=True)
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(run())
