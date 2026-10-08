# keel

Company-structure primitives that generalize: a small, pure, immutable Elixir
kernel in which sole proprietorships, partnerships, corporations, co-ops,
holdings, employee-owned firms (worker co-ops, ESOPs, EOTs), departments and AI-agent
staff are all configurations of the same eight sorts.

| Nodes | Edges (temporal, `[from, to)`) |
| --- | --- |
| `Party` — person \| entity \| agent | `Seat` — party holds role |
| `Unit` — container, forest per entity | `Line` — `:reports` / `:delegates` between roles |
| `Role` — grants + seat limit | `Stake` — units of a class in an entity |
| `Body` — decision rule, scope (`grants`, fail-closed), exclusive `reserves`, look-through `voices` | |
| `Class` — stake class with eligibility (e.g. employees only) | |

```elixir
alias Keel.{Forms, Org, Party, Decision}

org =
  Org.new([
    for(p <- [:ann, :bob, :cat], do: %Party{id: p, kind: :person}),
    Forms.worker_cooperative(:coop, [:ann, :bob, :cat], :ann, capital: %{ann: 5_000, bob: 100, cat: 100})
  ])

[] = Keel.check(org)
{:failed, _} = Decision.decide(org, {:coop, :assembly}, :resolve, %{ann: :yes, bob: :no, cat: :no}, ~D[2026-06-01])
```

- `Keel.Org` — construction and snapshot queries (`holders`, `capabilities`, `can?`, `members`)
- `Keel.Invariants` — sixteen named well-formedness checks, evaluated at every epoch
- `Keel.Decision` — scoped quorum / threshold decisions in exact rationals, with look-through voting by owning entities
- `Keel.Forms` — canonical forms; compose by list concatenation

The formal model, invariants, soundness lemmas and the record of policy amendments: [`docs/PRIMITIVES.md`](docs/PRIMITIVES.md).

```sh
mix test
```
