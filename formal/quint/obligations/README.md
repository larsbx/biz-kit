# Per-app obligation models

One Quint file per Proof Bank catalog app: `<app>.qnt`. Each one states that
app's catalogued `first_formal_obligation`
(`proof_bank/characterizations/v1/catalog.json`) as an invariant over an
abstract state machine of the rule that enforces it.

Each file has three modules:

- `<app>_spec`: the model. Its `const GUARDED: bool` switches the rule that
  enforces the obligation on or off. It defines `init`, `step`, the invariant
  `obligation` and the witness `obligationWitness`.
- `<app>`: `import <app>_spec(GUARDED = true).*`. It must satisfy `obligation`.
- `<app>_control`: `import <app>_spec(GUARDED = false).*`. It must **violate**
  `obligation`, which shows that the guard is what makes it hold.

`obligationWitness` is the negation of a meaningful state, so finding it
violated proves that the state is reachable and that `obligation` does not
hold vacuously.

`formal/check_coverage.sh` typechecks each model, simulates it, verifies it
with bounded Apalache, and checks the witness and the control. The models
abstract the rule, not the Elixir code: coverage here is **not** a claim that
the implementation refines the model.

## Where the code does not (fully) enforce the obligation

Coverage means the obligation is stated and checked over a model of the
rule. Writing the models showed that, for these apps, the guarded model is
the **intended** rule, and the code is weaker. Each model's header says so.
These are open defects or host duties, not proofs.

| App | Gap |
| --- | --- |
| dispatch | Driver exclusivity only for exclusive drivers (`one_active_per_operator`); nothing enforces vehicle or trailer exclusivity, so two active trips can share a vehicle |
| eatsbot_core | `UpdateHistory` writes the history row in `after_transaction`; a crash leaves state without history, so replay diverges. The code behaves like the control |
| biz_kit_cluster | No fencing token: after a partition heals, the losing instance exits asynchronously and an effect in that window is not fenced |
| spruce_goose | `AuthorityRuntime.ensure_local_execution_allowed/0` returns `:ok` when the marker file is missing (fails open) |
| keel | `Keel.Org.can?/4` applies the interval filter but never checks `Keel.Invariants.valid?/1` (cycles, well-formed intervals) |
| biz-kit | Dispatch, eatsbot and spruce_goose still write their own databases directly, bypassing `CoopSubstrate.Log.append/2` |
| eatsbot | The retirement cutover fence is not implemented; the legacy writer starts unconditionally |
| marketing_core | "Authenticated delivery" is the caller's `delivery_status: :confirmed`; `Attribution.eligible?/3` does not verify evidence |
| barter_core | Previews leave ownership unchanged; the signed admission that would transfer assets is a host duty, not in the core |
| federation_core | The core never attributes remote input to a local seller; not inferring authority from candidates is a host duty |

Holds by construction or scope, not by a check: biz_kit_extension (no grant,
invoke or write path exists), restaurant_host (the governance seed is never
sent; only "signs only what was shown" is guarded), hawala_capability
(test-only adapter), school_ops (free-text titles are unchecked and
unmodelled), eatsbot_extension_prometheus (`/metrics` authentication is
deployment configuration).
