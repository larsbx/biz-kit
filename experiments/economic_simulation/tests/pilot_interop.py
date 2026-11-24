#!/usr/bin/env python3
"""Replay synthetic projection controls through the canonical Elixir CLI.

Run from any directory. CI should pass --require-elixir so missing runtimes fail.
Without that flag, a missing Elixir executable reports an explicit skipped result.
The command starts no application, provider, ledger or source-data writer.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_pilot import canonical_controls, engine_controls  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--require-elixir", action="store_true")
    parser.add_argument(
        "--elixir", default="elixir", help="Elixir executable (OTP 27+ required)"
    )
    parser.add_argument(
        "--prepare-only",
        action="store_true",
        help="Validate engine controls without claiming canonical reader execution",
    )
    args = parser.parse_args(argv)
    if args.prepare_only and args.require_elixir:
        parser.error("--prepare-only cannot satisfy --require-elixir")
    try:
        hand_controls = canonical_controls()
        simulated_controls = engine_controls()
        controls = hand_controls + simulated_controls
    except (ValueError, KeyError, TypeError) as exc:
        print(
            json.dumps(
                {
                    "status": "failed",
                    "canonical_reader_executed": False,
                    "reason": str(exc),
                }
            )
        )
        return 1
    if args.prepare_only:
        print(
            json.dumps(
                {
                    "status": "prepared",
                    "canonical_reader_executed": False,
                    "hand_controls": len(hand_controls),
                    "engine_controls": len(simulated_controls),
                    "source": "synthetic",
                    "canonical_metric_acceptance": "pending",
                }
            )
        )
        return 0
    executable = shutil.which(args.elixir)
    if executable is None:
        print(
            json.dumps(
                {
                    "status": "failed" if args.require_elixir else "skipped",
                    "reason": "Elixir executable unavailable",
                    "canonical_reader_executed": False,
                }
            )
        )
        return 1 if args.require_elixir else 0
    commands = [{"op": "score", "snapshot": snapshot} for _, snapshot, _ in controls]
    # Negative controls prove that canonical validation receives the snapshots.
    bad_payment = json.loads(json.dumps(controls[0][1]))
    bad_payment["orders"][0]["gross_minor"] = 1000
    extra_field = json.loads(json.dumps(controls[0][1]))
    extra_field["simulation_commitment_rate"] = 1.0
    commands.extend(
        {"op": "score", "snapshot": item} for item in (bad_payment, extra_field)
    )
    try:
        completed = subprocess.run(
            [executable, str(ROOT / "tools/merchant_pilot/cli.exs"), "batch"],
            cwd=ROOT,
            input="".join(json.dumps(command) + "\n" for command in commands),
            text=True,
            capture_output=True,
            timeout=60,
            check=True,
        )
        reports = [
            json.loads(line) for line in completed.stdout.splitlines() if line.strip()
        ]
        if len(reports) != len(commands):
            raise ValueError("canonical reader returned the wrong number of reports")
        for (name, _, expected), response in zip(controls, reports):
            if response.get("ok") is not True:
                raise ValueError(f"canonical reader refused control: {name}")
            for path, value in expected.items():
                actual = response["report"]
                for part in path.split("."):
                    actual = actual[part]
                if actual != value:
                    raise ValueError(f"canonical metric mismatch: {name}: {path}")
        if any(
            response.get("ok") is not False for response in reports[len(controls) :]
        ):
            raise ValueError("canonical reader accepted a deliberate invalid snapshot")
    except (
        OSError,
        subprocess.SubprocessError,
        ValueError,
        KeyError,
        TypeError,
    ) as exc:
        print(
            json.dumps(
                {
                    "status": "failed",
                    "canonical_reader_executed": True,
                    "reason": str(exc),
                }
            )
        )
        return 1
    print(
        json.dumps(
            {
                "status": "passed",
                "canonical_reader_executed": True,
                "valid_controls": len(controls),
                "rejected_controls": 2,
                "hand_controls": len(hand_controls),
                "engine_controls": len(simulated_controls),
                "source": "synthetic",
                "reader": "CommerceCore.MerchantPilot.Scorecard",
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
