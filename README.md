# keel

Company-structure primitives that generalize: a small, pure, immutable Elixir
kernel in which sole proprietorships, partnerships, corporations, co-ops,
holdings, departments and AI-agent staff are all configurations of the same
seven sorts.

| Nodes | Edges (temporal, `[from, to)`) |
| --- | --- |
| `Party` — person \| entity \| agent | `Seat` — party holds role |
| `Unit` — container, forest per entity | `Line` — `:reports` / `:delegates` between roles |
| `Role` — grants + seat limit | `Stake` — units of a class in an entity |
| `Body` — collective decision rule | |

```elixir
alias Keel.{Forms, Org, Party, Decision}

org =
  Org.new([
    for(p <- [:ann, :bob, :cat], do: %Party{id: p, kind: :person}),
    Forms.cooperative(:coop, [:ann, :bob, :cat], :ann, capital: %{ann: 5_000, bob: 100, cat: 100})
  ])

[] = Keel.check(org)
{:failed, _} = Decision.decide(org, {:coop, :assembly}, %{ann: :yes, bob: :no, cat: :no}, ~D[2026-06-01])
```

- `Keel.Org` — construction and snapshot queries (`holders`, `capabilities`, `can?`, `members`)
- `Keel.Invariants` — ten named well-formedness checks, evaluated at every epoch
- `Keel.Decision` — quorum / threshold decisions in exact rationals
- `Keel.Forms` — canonical forms; compose by list concatenation

The formal model, invariants and their soundness lemmas: [`docs/PRIMITIVES.md`](docs/PRIMITIVES.md).

```sh
mix test
```
