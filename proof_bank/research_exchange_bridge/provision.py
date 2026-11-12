#!/usr/bin/env python3
"""Prepare a new disposable local fixture instance; never overwrite an instance."""
from __future__ import annotations

import argparse
import base64
from pathlib import Path
import secrets
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from research_exchange_bridge.common import (VERIFIER, canonical, core_identity, loads, sha)
from research_exchange_bridge.store import Store
from adapter_pilot.common import POLICY, canonical as profile_canonical


def provision(destination, profile, lean_root, python_executable):
    destination = Path(destination).absolute()
    destination.mkdir(mode=0o700, parents=True, exist_ok=False)
    key = secrets.token_bytes(32)
    token = secrets.token_urlsafe(40)
    core = core_identity()
    database = destination / "bridge.sqlite"
    store = Store(database, key)
    store.initialize()
    library = {"id": "reviewed-lean-fixture", "engine": "lean", "revision": core["revision"],
               "snapshot_sha256": profile["source_sha256"], "environment_sha256": profile["toolchain_lock_sha256"],
               "policy_sha256": sha(profile_canonical(POLICY)), "generation": 1}
    store.provision_library(library, profile)
    store.provision_grant(token, "local-researcher", [library["id"]],
                          ["library:read", "proof:submit", "verification:request"], int(time.time()) + 3600)
    bridge = {"database": str(database), "receipt_key_base64": base64.b64encode(key).decode(),
              "lean_root": str(Path(lean_root).resolve(strict=True)), "worker_enabled": True}
    outer = {"backend": "durable", "bridge_config": str(destination / "bridge.json"),
             "python_executable": str(Path(python_executable).resolve(strict=True))}
    for name, data in (("bridge.json", canonical(bridge)), ("mcp.json", canonical(outer)),
                       ("contributor.token", token.encode())):
        path = destination / name
        path.write_bytes(data)
        path.chmod(0o600)
    return {"config": str(destination / "mcp.json"), "token_file": str(destination / "contributor.token"),
            "database": str(database), "library": library, "scope": "disposable-exact-reviewed-export-only"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", required=True, type=Path)
    parser.add_argument("--profile", required=True, type=Path)
    parser.add_argument("--lean-root", required=True, type=Path)
    parser.add_argument("--python-executable", default=sys.executable, type=Path)
    args = parser.parse_args()
    print(canonical(provision(args.destination, loads(args.profile.read_bytes()), args.lean_root,
                              args.python_executable)).decode())


if __name__ == "__main__":
    main()
