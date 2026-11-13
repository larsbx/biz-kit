#!/usr/bin/env python3
"""Run one operator-selected durable job; no contributor command interface."""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from research_exchange_bridge.common import canonical, hexadecimal, load_config, receipt_key, require
from research_exchange_bridge.store import Store


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--job-id", required=True)
    parser.add_argument("--retry-inconclusive", action="store_true")
    parser.add_argument("--source-imports", type=Path)
    args = parser.parse_args()
    require(hexadecimal(args.job_id))
    config = load_config(args.config)
    store = Store(config["database"], receipt_key(config["receipt_key_base64"]))
    store.initialize()
    if args.retry_inconclusive:
        store.retry(args.job_id)
    failpoint = config.get("test_failpoint") if config.get("test_job_id", args.job_id) == args.job_id else None
    pause_path = config.get("test_pause_after_check") if config.get("test_pause_job_id", args.job_id) == args.job_id else None
    store.execute_one(args.job_id, config["lean_root"], source_root=args.source_imports,
                      failpoint=failpoint, pause_path=pause_path)
    observation = store.inspect(args.job_id)
    print(canonical({"job_id": args.job_id, "status": observation["receipt"]["payload"]["status"],
                     "version": observation["version"], "effects": len(observation["effects"])}).decode())


if __name__ == "__main__":
    main()
