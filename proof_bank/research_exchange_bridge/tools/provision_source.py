#!/usr/bin/env python3
"""Add the bounded Lean source capability to a local operator-owned bridge."""
import argparse
from pathlib import Path
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from research_exchange_bridge.common import canonical, load_config, receipt_key, sha
from research_exchange_bridge.store import Store
from research_exchange_bridge.source import REVISION, environment_identity, profile_for
from adapter_pilot.checker import ControlledChecker
from adapter_pilot.common import canonical as profile_canonical


def install(store, checker, imports):
    profile = profile_for(environment_identity(checker, imports))
    library = {"id": "lean-source-prime-two-v1", "engine": "lean", "revision": REVISION,
               "snapshot_sha256": profile["source_sha256"],
               "environment_sha256": profile["toolchain_lock_sha256"],
               "policy_sha256": sha(profile_canonical(profile["policy"])), "generation": 1}
    store.provision_library(library, profile)
    return library


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--source-imports", required=True, type=Path)
    parser.add_argument("--token-file", required=True, type=Path)
    parser.add_argument("--principal", required=True)
    args = parser.parse_args()
    token = args.token_file.read_text(encoding="ascii").strip()
    config = load_config(args.config)
    store = Store(config["database"], receipt_key(config["receipt_key_base64"]))
    store.initialize()
    library = install(store, ControlledChecker(config["lean_root"]), args.source_imports)
    store.provision_grant(token, args.principal, [library["id"]],
                          ["library:read", "proof:submit", "verification:request"], int(time.time()) + 3600)
    print(canonical(library).decode())


if __name__ == "__main__":
    main()
