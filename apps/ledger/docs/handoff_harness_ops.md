# Hand-off: Harness.Ops — the Operator CLI (Coding Agent)

**Scope of this hand-off:** make `docs/runbook_gate_d.md` executable without `iex` — a
thin command-line veneer (`CoopSubstrate.Harness.Ops` + `Mix.Tasks.Harness.*`) over the
existing harness machinery, for a single operator on the dev host running the field work.
It is NOT a UI, not a network service, not multi-operator, not outreach tooling, and it
adds **zero business rules** — every gate check already exists and stays where it is.

**Why now:** the runbook's appendix hand-signs every event through a pasted closure. The
field effort is weeks long and ceremony-heavy (an interviewee signing consent live, dozens
of findings per week, one deliberate adoption signature); the friction is no longer
hypothetical. This brief exists because the user called it, honoring the YAGNI line.

**Read before coding:** `docs/runbook_gate_d.md` (the CLI's requirements document — every
command below maps to a runbook phase), `HARNESS.md`, `SUBSTRATE.md` §15 (role keys),
`docs/corpus/08_PLATFORM.md` §9 (key-custody discipline: day-one trusted custody is
allowed **behind interfaces, labeled temporary**; premature crypto is a defect).

---

## 0. Non-negotiable invariants

1. **Thin veneer, single enforcement locus.** Commands build envelopes, sign, append, and
   print — they never duplicate a validity rule. UX hints (e.g. listing valid modes) are
   fine; pre-validation that could drift from the gate is not. On rejection, print the
   gate's error term **verbatim** — the atoms are named for runbook phases and that
   mapping is the help text.
2. **Interviewee seeds are theirs and are never persisted.** The consent ceremony
   generates the keypair, signs in-session, prints the seed once for handover (hex +
   the offer of a QR later), and drops it. Revocation reads the seed from stdin or a
   file the *interviewee* supplies — never from anything Ops wrote. A test proves no
   interviewee seed touches disk.
3. **Operator key custody is explicit and flagged temporary** (08 §9): role seeds
   (steward/governance/checkpoint) live as `0600` files under a directory outside the
   repo (`HARNESS_KEYS_DIR`), named by role. No passphrase vault, no threshold shares —
   plain files behind OS permissions, documented as the day-one trusted rung with the
   upgrade path named (key ceremony to threshold custody, 1D-flagged). Never echo a seed;
   never accept one as a shell argument (history leakage) — stdin or file paths only.
4. **Lax-direction acts stay deliberate.** `harness.adopt` (the one human signature) and
   role-key/constant declarations show exactly what will be signed (hashes, values) and
   require a typed confirmation string; everything strict-direction runs without prompts
   so it scripts.
5. **Scriptable by default**: batch inputs are files (findings, classifier, denylist);
   ids are explicit and human-readable (the operator cross-references them in
   corroborations), with a `--gen-id` ULID escape hatch; output is line-oriented
   (`event=<id> stream=<id>`), `--json` optional.

## 1. Command surface (each ↦ runbook phase)

```
harness.keys gen <role> | list | genesis        ↦ 0.2  (genesis = declarations + checkpoint
                                                        emission + prints the blob path
                                                        with a PUBLISH-THIS-EXTERNALLY nag)
harness.constants --n --c --d --k [--section D] ↦ 0.3  (four CharterConstantDeclared;
                                                        confirms values before signing)
harness.instrument publish [tree.json] | fetch <v> | diff <v1> <v2>   ↦ 0.4
harness.consent                                 ↦ 2    (the ceremony: prompts ref, classes,
                                                        recording; generates + hands over
                                                        the seed; signs; never persists)
harness.revoke <interviewee_ref>                ↦ 2    (seed via stdin/file)
harness.interview --section --interviewee --mode --id            ↦ 3
harness.findings <file.json> | --interview --id --kind --body    ↦ 3  (batch or single)
harness.document --interview --kind <path>      ↦ 3    (wraps Harness.collect_document)
harness.corroborate <claim> <finding...>        ↦ 4
harness.conflict <claim> <finding...>           ↦ 4
harness.status [--section D]                    ↦ 4,7  (gate verdict + counts + the short
                                                        legs named in runbook terms)
harness.model publish | show                    ↦ 5
harness.spec publish <classifier.json>          ↦ 5    (prints the three hashes)
harness.adopt --spec --defaults --model         ↦ 5    (governance key; typed confirmation)
harness.fixtures publish <dir> --denylist <file> --sources I-1,I-2   ↦ 6
harness.prospect --interview --track            ↦ 6
harness.honorarium --interviewee --amount       ↦ 0.1  (accrue only; payout stays gated)
harness.checkpoint                              ↦ 7    (emit + print path; publish nag)
harness.build-started [--section D]             ↦ 7
```

Machine-extraction commands are **deferred**: proposals come from tooling that doesn't
exist yet; when it does, it appends its own events (the type is live).

## 2. Build phases

### Phase 3A — signing core, key custody, ceremonies
`Harness.Ops` (envelope build/sign/append/print + key-dir handling) and the commands for
runbook phases 0 and 2: `keys`, `constants`, `instrument`, `consent`, `revoke`.
**Acceptance [3A]:** runbook 0.2–0.4 + a full consent ceremony run end-to-end with no
`iex`; no interviewee seed persisted (tested); a rejected append prints the gate's term
verbatim; operator key files are `0600` and never echoed.

### Phase 3B — capture through the gate
Everything else, plus `harness.status`'s short-leg naming.
**Acceptance [3B]:** the 2D end-to-end scenario reproduced **through the CLI alone** on
synthetic data (an integration test driving the task modules): constants → consents →
interviews → findings → documents → corroboration → model → spec → adoption → fixtures →
prospect → `status` true → `build-started`; then a revocation and `status` naming what
fell short. The 183-test suite untouched and green.

## 3. Open questions (owned here)

1. Seed handover format: hex printout now; QR (`--qr`) when a dependency is justified.
2. `--json` output schema — decide when the first consumer script exists, not before.
3. Whether `harness.status` should also verify the latest published checkpoint (nice
   audit habit; cheap; lean yes).
4. Key-file encryption at rest — deliberately not v0 (08 §9); revisit at the 1D
   threshold-custody milestone.

## 4. Deliverables

`docs/phase3{a,b}_plan.md` per repo convention (plan committed before build, deviations
flagged); the CLI green under the full suite; a short `## Operating` section appended to
`docs/runbook_gate_d.md` replacing the iex appendix as the primary path (the appendix
stays as the fallback). Where this brief and the runbook/corpus conflict, the corpus
governs — flag it.

**Gate out:** this brief changes no evidence semantics — `gate(D)` still waits on field
work; Ops just makes the field work one command per act.
