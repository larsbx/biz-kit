#!/usr/bin/env python3
"""Evaluate bounded TSV rows with the actual Quint oracle (no Python oracle).

Input:  Q<TAB>B<TAB>n<TAB>d
Output: status<TAB>quoteReduced<TAB>baseReduced<TAB>quoteResidual<TAB>baseResidual

The finite profile is Q,B in 0..8 and n,d in 0..5. Rejected rows preserve Q,B
as their residuals. Use the Lean/Elixir comparison for large integer boundaries.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


def evaluate_rows(rows: list[tuple[int, int, int, int]], quint_cli: str) -> list[list[int]]:
    if not rows:
        return []
    for row in rows:
        if len(row) != 4 or not all(0 <= x <= 8 for x in row[:2]) or not all(
            0 <= x <= 5 for x in row[2:]
        ):
            raise ValueError(f"outside the declared Quint finite profile: {row}")
    source = Path(__file__).with_name("ExactSetoff.qnt")
    # One expression per chunk keeps the parser's expression depth bounded.
    expressions = []
    for start in range(0, len(rows), 96):
        calls = ["row(" + ",".join(map(str, row)) + ")" for row in rows[start : start + 96]]
        expressions.append("List(" + ",".join(calls) + ")")
    process = subprocess.run(
        [quint_cli, "repl", "--quiet", "--backend=typescript", "--require", str(source) + "::ExactSetoff"],
        input="\n".join(expressions) + "\n",
        text=True,
        capture_output=True,
        timeout=180,
        check=False,
    )
    if process.returncode != 0 or process.stderr.strip():
        raise RuntimeError(f"Quint evaluation failed: {process.stdout}\n{process.stderr}")
    # Quint's REPL emits JSON arrays for lists of integers. Decode ALL output;
    # syntax errors or incomplete/extra output cannot silently count as success.
    decoder = json.JSONDecoder()
    remaining = process.stdout.strip()
    results: list[list[int]] = []
    chunks = 0
    while remaining:
        chunk, end = decoder.raw_decode(remaining)
        if not isinstance(chunk, list):
            raise RuntimeError(f"unexpected Quint output: {chunk!r}")
        results.extend(chunk)
        chunks += 1
        remaining = remaining[end:].lstrip()
    if chunks != len(expressions) or len(results) != len(rows) or any(
        not isinstance(row, list) or len(row) != 5 or any(type(x) is not int for x in row)
        for row in results
    ):
        raise RuntimeError("missing, extra or malformed Quint result rows")
    return results


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quint-cli", default=os.environ.get("QUINT_CLI", "quint"))
    args = parser.parse_args()
    rows = []
    for line_number, line in enumerate(sys.stdin, 1):
        if not line.strip():
            continue
        values = tuple(int(value) for value in line.split())
        if len(values) != 4:
            raise ValueError(f"line {line_number}: expected exactly four integers")
        rows.append(values)
    for row in evaluate_rows(rows, args.quint_cli):
        print("\t".join(map(str, row)))


if __name__ == "__main__":
    main()
