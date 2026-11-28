# FieldWitness pure consent proof candidate

Source: `961cfd7b9dd38fab2a6b9c43260ead81ba62a501`,
`apps/research_core/lib/research_core/access.ex`. This adds a pure model only.

The caller supplies a valid record with canonical narrator membership and a
well-typed review. The model preserves scope, record ID, narrator roster and
community; changes precisely one grant and increments revision. The model
specifies scope, revision, reviewer and no-op guard precedence. It includes
unanimity, withdrawal, pair isolation and stale-replay statements.

`eligibleBool` is executable; `eligible` is its proposition. The function-valued
Boolean grant map is an abstraction of MapSet membership, not a proof of
Elixir equivalence. The constructor deliberately assumes runtime input
validation: identifier syntax, uniqueness, sorting, 1–32 narrator limits,
malformed records, unknown actor tags and unsupported action/material/audience
values are not modeled. The listed nonreviewer tags remain disallowed.

A successful pure review does not authenticate an actor. No signed source
admission, key revocation, host concurrency, read fence, archive, payments or
publication authorization is implemented. Previously exported material cannot
be recalled. Publication remains blocked by the existing architecture contract.

Run with repository-pinned Lean 4.35.0:

```
cd formal/lean
lake build BizKitResearchConsent
lake env leanchecker --fresh --verbose BizKitResearchConsent
python3 -I check_research_consent_reference.py
```

The reference Python control enumerates all subsets of the three reviewers
across every ordered pair of material/audience pairs, plus actor, revision,
scope and action alternatives. It exercises 220,416 transitions; it is not
execution of either Lean or Elixir and does not establish correspondence.
The patch registers the module in the existing complete build, fresh kernel
replay and module axiom audit. Lean compilation and audit are pending.

Next: prove the persistent withdrawal property for traces without a regrant;
add source-pinned Elixir-to-Lean observations with malformed input cases;
model host authorization, key-epoch invalidation and read/write interleavings
in Quint before implementing signed admission and a delivery fence.
