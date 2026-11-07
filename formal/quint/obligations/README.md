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
These are open defects or host duties, not proofs; `docs/roadmap.md`
("Enforcement gaps") orders them. A closed gap leaves this table.

| App | Gap |
| --- | --- |
| spruce_goose | `AuthorityRuntime.ensure_local_execution_allowed/0` returns `:ok` when the marker file is missing (fails open) |
| biz-kit | Dispatch, eatsbot and spruce_goose still write their own databases directly, bypassing `CoopSubstrate.Log.append/2` |
| eatsbot | The retirement cutover fence is not implemented; the legacy writer starts unconditionally |

Enforced at the host, not in the core: marketing_core (the core trusts
`delivery_status: :confirmed`; `BizKit.MarketingBridge` binds it to a
host-verified receipt by id, digest and fields); federation_core
(`FederationService` is read-only; subscriptions become authority only via a
signed local grant through `CoopSubstrate.FederationAuthority`, except the
pilot `approval_verifier` path, which has no atomic revocation fence).

Holds by construction or scope, not by a check: barter_core (no code
transfers barter assets; the cores only preview and have no host), biz_kit_extension (no grant,
invoke or write path exists), restaurant_host (the governance seed is never
sent; only "signs only what was shown" is guarded), hawala_capability
(test-only adapter), school_ops (free-text titles are unchecked and
unmodelled), eatsbot_extension_prometheus (`/metrics` authentication is
deployment configuration), biz_kit_cluster (ledger appends are fenced by the
event store's expected-version check, so a stale appender is refused; other
singletons' in-memory state diverges per side during a partition, as
`docs/architecture/2026-10-19-cluster.md` records).
