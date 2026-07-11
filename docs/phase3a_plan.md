# Phase 3A — Harness.Ops: signing core, key custody, ceremonies

> **Status: IN PROGRESS** (2026-07-11). Scope is the Harness.Ops brief's Phase 3A
> (`docs/handoff_harness_ops.md` §2); acceptance = brief items **[3A]**. Covers runbook
> phases 0.2–0.4 and 2 (`docs/runbook_gate_d.md`). Normative outer authority: corpus
> 08 §9 (day-one trusted custody behind interfaces, labeled temporary), SUBSTRATE.md §15.

## §0 Spine

```
Ops            = build envelope → sign → append → report; ZERO duplicated rules — a
                 rejection is printed verbatim (the gate's atoms are the help text)
operator keys  = 0600 hex-seed files under HARNESS_KEYS_DIR (env; app-env fallback for
                 tests); gen never returns a seed; nothing ever echoes one — FLAGGED
                 temporary custody (08 §9), upgrade path is 1D threshold ceremony
interviewee    = ephemeral keypair at the ceremony: signed in-session, seed RETURNED
                 for handover, never persisted (tested); revocation derives key_id from
                 the seed the interviewee brings back
lax-direction  = typed confirmation (--yes for scripts, an explicit opt-out)
```

## Settled decisions

- **`CoopSubstrate.Harness.Ops`** is the core; Mix tasks (`Mix.Tasks.Harness.*`) are arg
  parsing + prompting + printing only, so tests target Ops functions and a thin layer of
  task invocations.
- **Key custody**: `gen_key(role)` (role ∈ declarable roles) writes `<dir>/<role>.seed`
  as hex, `chmod 0600`, and returns role/key_id/path — never the seed. `load_signer/1`
  derives pubkey and the `k-<hex4>` key_id convention from the seed. `keys_dir` resolves
  `HARNESS_KEYS_DIR` → `:harness_keys_dir` app env → a named error (custody is explicit,
  no silent default).
- **`genesis/1`**: generates any missing role keys, appends the TOFU governance
  declaration (self-signed) then the steward/checkpoint declarations under it, emits
  `Log.checkpoint/3`, writes the blob to a caller-named path, and returns it with the
  publish-this-externally nag — runbook 0.2 in one call.
- **`declare_constants/5`**: the four `CharterConstantDeclared` events, signed with the
  **governance seed under the `author` role** — `CharterConstantDeclared` is the 1A
  author-role type and `author` is not a declarable role, so it stays registry-unchecked;
  using the governance key material records whose act it was. FLAGGED: governance-gating
  the constants type itself is future H2 work.
- **`consent_ceremony/3`** returns `{interviewee_ref, key_id, seed_hex}` to the caller —
  the ONLY function that ever hands a seed upward, because handover is its purpose; it
  writes nothing. `revoke_consent/2` takes `interviewee_ref` + the seed (stdin/file at
  the task layer; never a shell argument).
- **`instrument_publish/1`** wraps `Instrument.publish` with the steward key; the task
  reads a JSON tree file (jason — already in the lock via eventstore, now declared) or
  defaults to `seed_d()`.
- **Rejection fidelity**: `Ops.append*` returns the log's error shape untouched; tasks
  print `REJECTED: <inspect(reason)>` and `Mix.raise` — no translation layer to drift.
- Ops is not added to the no-surveillance classification map: it is a write/ceremony
  surface with no member-data reads (`list_keys` reports the operator's own roles) —
  noted here so the omission is a decision, not an oversight.

## Build steps (TDD)

1. Plan doc (this file) — commit.
2. `Harness.Ops` core: keys_dir/gen_key/load_signer/list_keys; append/append_with;
   report formatting. `jason` declared; test config `harness_keys_dir`.
3. Ceremonies: `genesis/1`, `declare_constants/5`, `consent_ceremony/3`,
   `revoke_consent/2`, `instrument_publish/1`.
4. Mix tasks: `harness.keys` (gen/list/genesis), `harness.constants`,
   `harness.instrument` (publish/fetch/diff), `harness.consent`, `harness.revoke`.
5. Tests: key files 0600 + no seed in any return/echo; genesis end-to-end (registry
   populated, checkpoint blob verifies); constants + ceremony + revocation over the real
   log with a per-test keys dir; ceremony persists no seed (keys-dir snapshot unchanged);
   wrong-seed revocation rejected verbatim; task-layer smoke tests via `capture_io`
   (seed printed exactly once at the ceremony; `--yes` bypasses the typed confirmation).
6. Acceptance [3A] recorded; status flip — commit.

## Properties

```
P1  no operator seed is ever returned, printed, or logged; key files are 0600
P2  the consent ceremony persists nothing; the seed appears exactly once, in the
    handover output; revocation succeeds only with that seed (key_id re-derived)
P3  every gate rejection surfaces verbatim through Ops and the tasks
P4  genesis leaves the chapter with governance/steward/checkpoint declared and an
    externally verifiable checkpoint blob on disk
P5  lax-direction commands require typed confirmation unless --yes; strict-direction
    commands never prompt
P6  Ops adds no validity logic: removing any Ops-side check leaves behavior identical
    (there are none to remove)
```

## Adversarial

Seed via shell argument (not accepted — stdin/file only) · seed leakage through error
messages or `inspect` of signer structs (redact seeds in any printable struct) · keys dir
world-readable (perm test) · genesis re-run (second TOFU rejected by the gate; genesis
must be idempotent-safe: it reports, it does not retry declarations already made) ·
ceremony crash after keypair but before append (nothing persisted either way — the
keypair simply evaporates).

**Gate:** 3B (capture through the gate) starts only when [3A] passes.
