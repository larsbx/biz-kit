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
