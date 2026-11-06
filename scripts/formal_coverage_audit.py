#!/usr/bin/env python3
"""Formal obligation coverage gate (ratchet).

Every Proof Bank catalog app must be either covered, with at least one Lean
theorem or Quint invariant stating its catalogued first formal obligation,
or listed as uncovered. The uncovered list may only shrink. This audit is
static; `formal/check_coverage.sh` runs the covered models. Coverage means
that the model states and checks the obligation. It does NOT mean that the
Elixir implementation refines the model.
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

SCHEMA = "biz-kit.formal-coverage.v1"
COVERAGE = "formal/coverage.json"
CATALOG = "proof_bank/characterizations/v1/catalog.json"
DEFAULT_STEPS = 6
OBLIGATIONS = "formal/quint/obligations/"


def safe(root, item):
    p = Path(item)
    return not p.is_absolute() and ".." not in p.parts and (root / p).is_file()


def declares(text, keyword, name):
    return re.search(rf"^\s*(?:private\s+)?{keyword}\s+{re.escape(name)}\b", text, re.M) is not None


def lean_problems(root, app, entry):
    module, theorem = entry.get("lean", ""), entry.get("theorem", "")
    path = root / "formal/lean" / f"{module}.lean"
    if not re.fullmatch(r"[A-Z][A-Za-z0-9]*", module) or not path.is_file():
        return [f"{app}: missing Lean module {module}"]
    short = theorem.rsplit(".", 1)[-1]
    lakefile = (root / "formal/lean/lakefile.toml").read_text()
    check = (root / "formal/lean/check.sh").read_text()
    return [msg for ok, msg in [
        (declares(path.read_text(), "theorem", short),
         f"{app}: theorem {short} not declared in formal/lean/{module}.lean"),
        (re.search(rf'defaultTargets\s*=\s*\[[^\]]*"{module}"', lakefile),
         f"{app}: module {module} is not a lake default target"),
        (re.search(rf"for root in [^;\n]*\b{module}\b", check),
         f"{app}: module {module} is not axiom-audited by formal/lean/check.sh"),
    ] if not ok]


def quint_problems(root, app, entry):
    model = entry.get("quint", "")
    if not (model.endswith(".qnt") and safe(root, model)):
        return [f"{app}: unsafe or missing model path {model}"]
    text = (root / model).read_text()
    problems = [f"{app}: val {name} not declared in {model}"
                for name in (entry.get("invariant", ""), entry.get("witness"))
                if name is not None and not declares(text, "val", name)]
    problems += [f"{app}: module {name} not declared in {model}"
                 for name in (entry.get("main"), entry.get("control"))
                 if name is not None and not declares(text, "module", name)]
    if not entry.get("witness"):
        problems.append(f"{app}: a Quint entry needs a non-vacuity witness")
    if model.startswith(OBLIGATIONS) and not entry.get("control"):
        problems.append(f"{app}: an obligation model needs a negative control module")
    return problems


def artifact_problems(root, app, entry):
    if "lean" in entry:
        return lean_problems(root, app, entry)
    if "quint" in entry:
        return quint_problems(root, app, entry)
    return [f"{app}: artifact is neither Lean nor Quint"]


def audit(root, catalog_ids, coverage, base=None):
    problems = [] if coverage.get("schema") == SCHEMA else ["bad schema"]
    covered, uncovered = coverage.get("covered", {}), set(coverage.get("uncovered", []))
    ids = set(catalog_ids)
    for label, names in [("unaccounted", ids - set(covered) - uncovered),
                         ("both covered and uncovered", set(covered) & uncovered),
                         ("not in the catalog", (set(covered) | uncovered) - ids)]:
        if names:
            problems.append(f"{label}: {sorted(names)}")
    for app, entries in covered.items():
        if not entries:
            problems.append(f"{app}: covered without an artifact")
        for entry in entries:
            problems += artifact_problems(root, app, entry)
    if base is not None:
        grown = uncovered - set(base.get("uncovered", []))
        if grown:
            problems.append(f"ratchet: newly uncovered {sorted(grown)}")
    return problems


def ratio(coverage, catalog_ids):
    return len(set(coverage.get("covered", {})) & set(catalog_ids)), len(set(catalog_ids))


def quint_checks(coverage):
    seen = {(e["quint"], e.get("main", "-"), e.get("control", "-"), e["invariant"], e["witness"],
             e.get("max_steps", DEFAULT_STEPS))
            for entries in coverage.get("covered", {}).values() for e in entries if "quint" in e}
    return sorted(seen)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument("--base-ref", help="git ref whose coverage.json the uncovered list may not exceed")
    parser.add_argument("--quint-checks", action="store_true", help="print 'model main control invariant witness steps' lines")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    coverage = json.loads((root / COVERAGE).read_text(encoding="utf-8"))
    if args.quint_checks:
        for check in quint_checks(coverage):
            print(*check)
        return 0
    catalog_ids = [r["id"] for r in json.loads((root / CATALOG).read_text(encoding="utf-8"))["records"]]
    base = None
    if args.base_ref:
        shown = subprocess.run(["git", "-C", str(root), "show", f"{args.base_ref}:{COVERAGE}"],
                               capture_output=True, text=True)
        base = json.loads(shown.stdout) if shown.returncode == 0 else None
    problems = audit(root, catalog_ids, coverage, base)
    done, total = ratio(coverage, catalog_ids)
    print(json.dumps({"covered": done, "catalog": total, "percent": round(100 * done / total, 1),
                      "uncovered": sorted(coverage.get("uncovered", [])),
                      "ratchet_base": args.base_ref if base is not None else None,
                      "refinement_claimed": False, "problems": problems}, indent=2))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
