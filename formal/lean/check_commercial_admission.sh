#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Caller installs the repository-pinned Lean and puts its bin directory on PATH.
# A fresh olean is compiled from this checkout; no restored project proof is used.
evidence_dir=${COMMERCIAL_ADMISSION_EVIDENCE_DIR:-$(mktemp -d "${RUNNER_TEMP:-/tmp}/commercial-admission-lean.XXXXXX")}
mkdir -p "$evidence_dir"
export COMMERCIAL_ADMISSION_EVIDENCE_DIR="$evidence_dir"

python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

root = Path.cwd()
out = Path(os.environ["COMMERCIAL_ADMISSION_EVIDENCE_DIR"]).resolve()
module = "BizKitCommercialAdmission"
source = root / (module + ".lean")
source_digest = hashlib.sha256(source.read_bytes()).hexdigest()
checker_digest = hashlib.sha256((root / "check_commercial_admission.sh").read_bytes()).hexdigest()
env = dict(os.environ)
env["LEAN_PATH"] = str(out) + (os.pathsep + env["LEAN_PATH"] if env.get("LEAN_PATH") else "")

# Fixed proof inventory: deletion/renaming of an obligation is an error.
targets = """
ready_iff
protected_blocks_legacy_netting
protected_blocks_legacy_discharge
protected_blocks_legacy_assignment
protected_blocks_legacy_intent
unsupported_profile_fails_closed
activation_requires_current_governance
activation_rejects_unknown_version
activation_is_monotonic
activation_protects
activation_does_not_change_other_chapter
refused_stutters
changed_state_requires_ready
unknown_version_refused
unsupported_profile_refused
mismatched_profile_event_refused
changed_profile_event_hash_refused
unchecked_signatures_refused
revoked_authority_refused
stale_authority_refused
changed_governance_declaration_refused
changed_member_key_revision_refused
substituted_keys_refused
mismatched_current_source_refused
changed_revision_refused
changed_original_event_hash_refused
changed_original_event_id_refused
changed_latest_event_id_refused
changed_latest_event_hash_refused
assigned_lineage_refused
closed_source_refused
accepted_reserves_exact_sources
accepted_preserves_unlisted_sources
accepted_records_intent_once
reserved_source_refused
seen_intent_refused
exact_retry_has_no_second_effect
competing_proposal_refused
proposal_never_discharges
proposal_never_rewrites_sources
proposal_never_changes_profile
source_revision_is_not_reservation_identity
chapter_is_part_of_reservation_identity
replay_append_agrees_with_record_fold
accepted_append_reconstructs_after_restart
replay_of_prior_proposal_survives_current_revocation
reserve_preserves_existing_reservation
replay_suffix_preserves_existing_reservation
recorded_source_stays_reserved_after_restart
protected_new_legacy_close_is_refused
historical_legacy_close_still_replays
nonvacuous_ready
nonvacuous_acceptance
nonvacuous_conflict_refusal
nonvacuous_revocation_refusal
nonvacuous_revision_refusal
nonvacuous_restart_reservation
""".split()
text = source.read_text()
actual = re.findall(r"^theorem\s+(\w+)", text, re.MULTILINE)
if actual != targets:
    raise SystemExit("commercial proof inventory changed; review the fixed target list")
if re.search(r"\b(sorry|admit)\b", text) or re.search(r"^\s*(axiom|unsafe)\b", text, re.MULTILINE):
    raise SystemExit("commercial source contains a forbidden proof escape")

def run(name, args, expect_success=True):
    result = subprocess.run(args, cwd=root, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (out / (name + ".log")).write_text(result.stdout)
    if expect_success and result.returncode:
        raise SystemExit(f"{name} failed ({result.returncode}); see {out / (name + '.log')}")
    return result

version = run("lean-version", ["lean", "--version"]).stdout.strip()
pin = (root / "lean-toolchain").read_text().strip().split(":v")[-1]
if f"version {pin}," not in version:
    raise SystemExit(f"wrong Lean version: expected {pin}; observed {version}")
run("compile", ["lean", "-o", str(out / (module + ".olean")), str(source)])

audit = out / "Audit.lean"
audit.write_text("import " + module + "\n" + "\n".join(
    "#print axioms " + module + "." + name for name in targets) + "\n")
audit_text = run("axioms", ["lean", str(audit)]).stdout
allowed = {"propext", "Classical.choice", "Quot.sound"}
dependencies = {}
for name in targets:
    full = module + "." + name
    pattern = re.escape("'" + full + "'") + r" (?:depends on axioms: \[([^\]]*)\]|does not depend on any axioms)"
    matches = re.findall(pattern, audit_text)
    if len(matches) != 1:
        raise SystemExit("missing or duplicate compiled axiom report: " + full)
    axioms = {x.strip() for x in matches[0].split(",") if x.strip()}
    if not axioms <= allowed:
        raise SystemExit("unapproved compiled axioms for " + full + ": " + str(sorted(axioms)))
    dependencies[full] = sorted(axioms)

# Every control must fail because Lean evaluated the requested false statement;
# parser/import/type errors and process failure are not accepted as evidence.
controls = {
    "ProtectedLegacyBypass": "profileAllows .protectedV2 .legacyNetting = true",
    "UnknownVersion": "(appendProposal exampleState { exampleProposal with version := 3 } true).book.count = 1",
    "SubstitutedProfileEvent": "(appendProposal exampleState { exampleProposal with profileRef := { exampleProfileRef with eventHash := 999 } } true).book.count = 1",
    "UncheckedSignatures": "(appendProposal exampleState exampleProposal false).book.count = 1",
    "SubstitutedSameTotal": "(appendProposal exampleState { exampleProposal with sources := [{ exampleFirst with key := ⟨1, 3⟩ }, exampleSecond] } true).book.count = 1",
    "ChangedOriginalHash": "(appendProposal exampleState { exampleProposal with sources := [{ exampleFirst with originalEventHash := 999 }, exampleSecond] } true).book.count = 1",
    "ChangedLatestEvent": "(appendProposal exampleState { exampleProposal with sources := [{ exampleFirst with latestEventId := 999 }, exampleSecond] } true).book.count = 1",
    "ChangedRevision": "(appendProposal exampleState { exampleProposal with sources := [{ exampleFirst with revision := 1 }, exampleSecond] } true).book.count = 1",
    "ConflictingProposal": "(appendProposal (appendProposal exampleState exampleProposal true) { exampleProposal with intent := 32 } true).book.count = 2",
    "RevokedAuthority": "(appendProposal { exampleState with authorityActive := fun _ => false } exampleProposal true).book.count = 1",
    "StaleDeclaration": "(appendProposal exampleState { exampleProposal with authority := { exampleAuthority with declarationEventId := 99 } } true).book.count = 1",
    "ProposalDischarges": "(appendProposal exampleState exampleProposal true).sourceOpen exampleFirst.key = false",
    "RestartLosesReservation": "(replayBook [exampleProposal]).owner exampleFirst.key = none",
    "HistoricCloseReinterpreted": "(replayLegacyClose exampleState [exampleFirst.key]).sourceOpen exampleFirst.key = true",
}
for name, proposition in controls.items():
    path = out / (name + ".lean")
    path.write_text("import " + module + "\nopen " + module +
                    "\ntheorem forbidden : " + proposition + " := by decide\n")
    result = run(name, ["lean", str(path)], expect_success=False)
    if result.returncode == 0 or "Tactic `decide` proved that the proposition" not in result.stdout or "is false" not in result.stdout:
        raise SystemExit("negative control was not refuted for the intended reason: " + name)

# Same-kernel replay from a fresh process, distinct from elaboration and the
# independent Quint model. This is deliberately not called a second kernel.
run("kernel-replay", ["leanchecker", "--fresh", "--verbose", module])
if hashlib.sha256(source.read_bytes()).hexdigest() != source_digest or hashlib.sha256((root / "check_commercial_admission.sh").read_bytes()).hexdigest() != checker_digest:
    raise SystemExit("proof source or checker changed during verification")
receipt = {
    "schema": "commercial-admission-lean/v1",
    "source_sha256": source_digest,
    "checker_sha256": checker_digest,
    "lean_version": version,
    "registered_theorems": len(targets),
    "compiled_axiom_dependencies": dependencies,
    "intended_false_theorem_controls": list(controls),
    "kernel_replay": "passed; same Lean kernel, fresh process",
    "scope": "conditional abstract admission and reservation recovery; no Elixir refinement, corporate agency, discharge, accounting or settlement proof",
}
(out / "receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
print(f"PASS: {len(targets)} registered Lean properties, compiled axiom audit, {len(controls)} intended false-theorem controls, fresh kernel replay")
print(f"Evidence: {out}")
PY
