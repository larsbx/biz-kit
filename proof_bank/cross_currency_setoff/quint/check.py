#!/usr/bin/env python3
"""Run deterministic Quint tests and require behavioral source mutants to fail.

Outputs one JSON receipt on stdout. Logs are retained under --out-dir when given.
No randomized-state-space or Apalache result is claimed by this checker.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


TESTS = [
    "exhaustiveArithmeticTest",
    "explicitArithmeticTest",
    "noncanonicalAndInvalidTest",
    "identityAndCurrencyTest",
    "staleAndFutureAgreementTest",
    "reciprocalDistinctSourceTest",
    "changedSourceAssertionTest",
    "roundingAndCurrencyAggregationTest",
    "hostAssertionsAreNotAuthenticationTest",
]

# Each mutant changes the actual independently executed Quint source. Every
# mutant must still typecheck, then fail the designated behavioral assertion.
MUTATIONS = {
    "noncanonical_rate": (
        "n > 0 and d > 0 and 1.to(n).forall(g =>\n      n % g != 0 or d % g != 0 or g == 1)",
        "n > 0 and d > 0",
        "noncanonicalAndInvalidTest",
    ),
    "minimum_instead_of_maximum": (
        "if (p._2 > best._2) p else best",
        "if (p._2 < best._2) p else best",
        "explicitArithmeticTest",
    ),
    "inverted_rate": (
        "p._1 * d == p._2 * n",
        "p._1 * n == p._2 * d",
        "explicitArithmeticTest",
    ),
    "rounding_extra_quote_unit": (
        "else { status: 2, quote: p._1, base: p._2,",
        "else { status: 2, quote: p._1 + 1, base: p._2,",
        "exhaustiveArithmeticTest",
    ),
    "discard_source_revision": (
        "sourceId: s.id, sourceRevision: s.revision, currency: s.currency,",
        "sourceId: s.id, sourceRevision: 0, currency: s.currency,",
        "identityAndCurrencyTest",
    ),
    "accept_expired_agreement": (
        "r.agreedAt >= 0, r.agreedAt <= now, r.until > now,",
        "r.agreedAt >= 0, r.agreedAt <= now, r.until >= now,",
        "staleAndFutureAgreementTest",
    ),
    "aggregate_currencies": (
        "totals: if (a.currency < b.currency) List(total(qa), total(bb))\n        else List(total(bb), total(qa)),",
        "totals: List({ currency: a.currency, original: qa.original + bb.original,\n"
        "        reduced: qa.reduced + bb.reduced, residual: qa.residual + bb.residual }),",
        "identityAndCurrencyTest",
    ),
    "omit_candidate_equality": (
        "expected.accepted and expected == candidate",
        "expected.accepted",
        "changedSourceAssertionTest",
    ),
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quint-cli", default=os.environ.get("QUINT_CLI", "quint"))
    parser.add_argument("--out-dir", type=Path)
    args = parser.parse_args()
    source = Path(__file__).with_name("ExactSetoff.qnt")
    original = source.read_text()
    inventory = re.findall(r"^  run (\w+) =", original, flags=re.MULTILINE)
    if inventory != TESTS:
        raise RuntimeError(f"unexpected named test inventory: {inventory}")
    version = subprocess.check_output([args.quint_cli, "--version"], text=True).strip()
    if version != "0.33.1":
        raise RuntimeError(f"expected Quint 0.33.1, got {version}")
    if args.out_dir:
        args.out_dir.mkdir(parents=True, exist_ok=True)

    def execute(label: str, arguments: list[str]) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            [args.quint_cli, *arguments], text=True, capture_output=True, timeout=180, check=False
        )
        if args.out_dir:
            (args.out_dir / f"{label}.log").write_text(result.stdout + result.stderr)
        return result

    checked = execute("typecheck", ["typecheck", str(source)])
    if checked.returncode != 0:
        raise RuntimeError(f"baseline Quint typecheck failed: {checked.stdout}{checked.stderr}")
    baseline = execute("tests", ["test", "--backend=typescript", "--max-samples=1", "--seed=1", str(source)])
    if baseline.returncode != 0:
        raise RuntimeError(f"baseline Quint tests failed: {baseline.stdout}{baseline.stderr}")
    passed = re.findall(r"ok (\w+) passed 1 test\(s\)", baseline.stdout)
    if passed != TESTS or "9 passing" not in baseline.stdout:
        raise RuntimeError(f"unexpected test completion: {baseline.stdout}{baseline.stderr}")

    mutations = []
    with tempfile.TemporaryDirectory(prefix="setoff-quint-mutants-") as temp:
        for name, (needle, replacement, test) in MUTATIONS.items():
            if original.count(needle) != 1:
                raise RuntimeError(f"mutation anchor changed: {name}")
            target = Path(temp) / name / "ExactSetoff.qnt"
            target.parent.mkdir()
            target.write_text(original.replace(needle, replacement))
            typed = execute(name + "-typecheck", ["typecheck", str(target)])
            if typed.returncode != 0:
                raise RuntimeError(f"mutant did not typecheck: {name}: {typed.stdout}{typed.stderr}")
            result = execute(name, ["test", "--backend=typescript", "--max-samples=1", "--seed=1",
                                    "--match", "^" + test + "$", str(target)])
            if result.returncode == 0 or "[QNT508]" not in result.stdout + result.stderr or (
                test + " failed after 1 test(s)"
            ) not in result.stdout:
                raise RuntimeError(f"mutant not behaviorally rejected: {name}: {result.stdout}{result.stderr}")
            mutations.append({"name": name, "typecheck": "passed", "test": test,
                              "outcome": "expected_assertion_failure"})

    print(json.dumps({
        "quint_version": version,
        "backend": "typescript",
        "source_sha256": hashlib.sha256(original.encode()).hexdigest(),
        "named_tests": TESTS,
        "named_tests_passed": len(TESTS),
        "finite_arithmetic_domain": {"quote_amount": [0, 8], "base_amount": [0, 8],
                                     "numerator": [0, 5], "denominator": [0, 5]},
        "exhaustive_input_rows": 2916,
        "method": "deterministic finite universal quantification and integer-pair enumeration",
        "apalache_model_checking": "not_run",
        "mutations": mutations,
        "authority": "host_assertions_only",
        "hash_model": "transparent_structured_preimage_only",
    }, indent=2))


if __name__ == "__main__":
    main()
