# Keel primitives — formal model

## Sorts

| Sort | Symbol | Struct | Fields |
| --- | --- | --- | --- |
| Time | 𝕋 | `Date` | total order; intervals `I = [a, b)`, `a, b ∈ 𝕋 ∪ {±∞}`, `a < b` |
| Party | 𝒫 | `Keel.Party` | `kind : 𝒫 → {person, entity, agent}`; `𝒫ₑ ≔ kind⁻¹(entity)` |
| Unit | 𝒰 | `Keel.Unit` | `of : 𝒰 → 𝒫ₑ`, `parent : 𝒰 ⇀ 𝒰` |
| Role | ℛ | `Keel.Role` | `unit : ℛ → 𝒰`, `grants : ℛ → 𝒫(𝒞)`, `seats : ℛ → ℕ⁺ ∪ {∞}` |
| Body | ℬ | `Keel.Body` | `of : ℬ → 𝒫ₑ`, members selector, weight, quorum `q ∈ ℚ`, pass `(⋈, θ)`, `⋈ ∈ {>, ≥}` |
| Capability | 𝒞 | `Keel.Capability` | preorder `⊒` (below) |

Node ids share one namespace. Edges carry a validity interval:

```
Seat      ⊆ 𝒫 × ℛ × I                      p holds r
Line_rep  ⊆ ℛ × (ℛ ∪ ℬ) × I                r answers to x
Line_del  ⊆ ℛ × ℛ × 𝒫(𝒞) × I               r confers G on r'
Stake     ⊆ 𝒫 × 𝒫ₑ × Class × ℕ⁺ × I        p holds n units of class c in e
```

The snapshot `σ_t` keeps the edges whose interval contains `t`. All queries are
functions of `(org, t)`; history is never mutated — change is a new interval.

## Capabilities

```
* ⊒ c          k ⊒ k          k ⊒ (k, n)          (k, a) ⊒ (k, b)  ⟺  a ≥ b
H ⊒ c  ⟺  ∃h ∈ H. h ⊒ c
```

`⊒` is a preorder (reflexive, transitive), so covering composes along chains.

## Derived functions at `t`

```
holders(r)  = { p | (p, r) ∈ Seat_t }
eff(r)      = grants(r) ∪ ⋃{ G | (r', r, G) ∈ Line_del,t }
caps(p)     = ⋃{ eff(r) | (p, r) ∈ Seat_t }
members(b)  = holders(R)                       if b selects {:seats, R}
            = { p | (p, of(b), c, _) ∈ Stake_t }  if b selects {:stake, c}
w_b(p)      = 1                                 per_capita
            = Σ{ n | (p, of(b), c, n) ∈ Stake_t }  {:units, c}
```

Decision with votes `v : 𝒫 ⇀ {yes, no, abstain}`, `W(S) = Σ_{p∈S∩members(b)} w_b(p)`:

```
inquorate  ⟺  W(dom v) < q · W(members)
carried    ⟺  ¬inquorate ∧ Y + N > 0 ∧ Y ⋈ θ·(Y + N)      Y = W(v⁻¹ yes), N = W(v⁻¹ no)
```

Arithmetic is exact (integer cross-multiplication of rationals).

## Invariants (`Keel.Invariants`)

Static:

| # | Name | Statement |
| --- | --- | --- |
| I1 | `references` | every reference resolves to a node of the required sort (`of`, `in` ∈ 𝒫ₑ) |
| I2 | `kinds` | party / line kinds and body shapes are in their enumerations |
| I3 | `intervals` | every edge interval is non-empty |
| I4 | `stakes` | units ∈ ℕ⁺ |
| I5 | `unit_forest` | `parent` is acyclic and `of(parent(u)) = of(u)` |

Temporal, ∀t:

| # | Name | Statement |
| --- | --- | --- |
| I6 | `reports_acyclic` | `Line_rep,t` is a DAG (matrix orgs allowed; loops not) |
| I7 | `delegation_acyclic` | `Line_del,t` is a DAG |
| I8 | `attenuation` | `(r, r', G) ∈ Line_del,t ⟹ ∀g ∈ G. eff(r) ⊒ g` |
| I9 | `seat_limits` | `|holders(r)| ≤ seats(r)` |
| I10 | `agent_accountability` | `kind(p) = agent ∧ (p, r) ∈ Seat_t ⟹ r →*_rep x` with some non-agent in `holders(x)` or `members(x)` |

**Lemma (epochs).** `σ_t` is constant on each `[eᵢ, eᵢ₊₁)` where `e₀ = −∞`
(represented by `Date.new!(-9999, 1, 1)`) and `e₁ < e₂ < …` are the finite
interval bounds. Hence checking I6–I10 at `{eᵢ}` decides them ∀t. ∎

**Lemma (delegation soundness).** If I7 and I8 hold at `t`, then
`∀r ∀c ∈ eff(r). ∃r₀. grants(r₀) ⊒ c` — no authority exists that is not
covered by some intrinsic grant.
*Proof.* Induction on a topological order of the DAG `Line_del,t`. Sources have
`eff = grants`. For `c` delegated by `r'` earlier in the order, I8 gives
`eff(r') ⊒ c`, the hypothesis gives an intrinsic cover of that witness, and `⊒`
is transitive. ∎

I7 is necessary, not merely tidy: with `a ⇄ b` each delegating `hire` and
neither granted it, `eff(a) = eff(b) = {hire}` satisfies I8 point-wise while
authority comes from nowhere (`test/invariants_test.exs`, "launders").

## Generalization: forms are configurations

| Form | Control | Economics | Executive answers to |
| --- | --- | --- | --- |
| Sole proprietorship | owners body, `{:units, :equity}`, one holder | same stake | owners |
| Partnership / LLC | owners body, `{:units, :equity}` | same stake | owners |
| Corporation | shareholders `{:units, :common}` → board `{:seats, director}` per capita | `:common` | board |
| Worker co-op | assembly `{:stake, :membership}` per capita | `:capital`, separate class | assembly |
| Holding | subsidiary's owners body has an entity member | entity stake | composition of two corporations |
| Department | `Unit` under `hq`; head has no intrinsic grants | — | superior role, which delegates |
| Agent staff | agent `Party` seated in a role | — | I10: a chain ending in a non-agent |

Each row is a test in `test/forms_test.exs` that builds the form and asserts
`Invariants.check/1 == []`. One person holding several roles (owner-operator)
needs no special case: `Seat` is a relation, not a function.

## Scope

In: who exists, who holds what position, who answers to whom, who may do what,
who owns what, and how groups decide. Out (by design, belongs elsewhere):
money movements and ledgers, workflows and tasks, documents and files,
contracts between entities. Those systems reference Keel ids rather than
re-encode structure.
