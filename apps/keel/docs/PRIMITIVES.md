# Keel primitives — formal model

## Sorts

| Sort | Symbol | Struct | Fields |
| --- | --- | --- | --- |
| Time | 𝕋 | `Date` | total order; intervals `I = [a, b)`, `a, b ∈ 𝕋 ∪ {±∞}`, `a < b` |
| Party | 𝒫 | `Keel.Party` | `kind : 𝒫 → {person, entity, agent}`; `𝒫ₑ ≔ kind⁻¹(entity)` |
| Unit | 𝒰 | `Keel.Unit` | `of : 𝒰 → 𝒫ₑ`, `parent : 𝒰 ⇀ 𝒰` |
| Role | ℛ | `Keel.Role` | `unit : ℛ → 𝒰`, `grants : ℛ → 𝒫(𝒞)`, `seats : ℛ → ℕ⁺ ∪ {∞}` |
| Body | ℬ | `Keel.Body` | `of : ℬ → 𝒫ₑ`, members selector, weight, quorum `q ∈ ℚ`, pass `(⋈, θ)`, `⋈ ∈ {>, ≥}`, `grants : ℬ → 𝒫(𝒞)` (default `∅`, fail-closed), `reserves : ℬ → 𝒫(𝒞)` (default `∅`), `voices : ℬ → 𝒫(𝒞)` (default `∅`) |
| Class | 𝒦 | `Keel.Class` | `of : 𝒦 → 𝒫ₑ`, `name`, `employer : 𝒦 ⇀ 𝒫ₑ` (`eligible: :employees \| {:employees, e}`), `tenure ∈ {binding, revocable}` (*lāzim* / *jāʾiz*), `preemption ∈ 𝔹` (*shufʿa*) |
| Asset | 𝒳 | `Keel.Asset` | `of : 𝒳 → 𝒫ₑ`, `quantity ∈ ℕ⁺`, `divisible ∈ 𝔹` |
| Capability | 𝒞 | `Keel.Capability` | preorder `⊒` (below) |

Node ids share one namespace. Edges carry a validity interval:

```
Seat      ⊆ 𝒫 × ℛ × I                      p holds r
Line_rep  ⊆ ℛ × (ℛ ∪ ℬ) × I                r answers to x
Line_del  ⊆ (ℛ ∪ ℬ) × (ℛ ∪ ℬ) × 𝒫(𝒞) × I   x confers G on x'
Line_man  ⊆ 𝒫 × ℬ × 𝒫(𝒞) × I               owner p mandates body b for G (wakāla; revoked by ending I)
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
eff(x)      = grants(x) ∪ ⋃{ G | (x', x, G) ∈ Line_del,t }        x ∈ ℛ ∪ ℬ
employs(e, p) ⟺ ∃(p, r) ∈ Seat_t. of(unit(r)) = e
voices(e, m) = ⟨b₁, b₂, …⟩ bodies of e with some v ∈ voices(b) ⊒ m, most specific v first
caps(p)     = ⋃{ eff(r) | (p, r) ∈ Seat_t }                        (raw, before reservation)
ent(x)      = of(unit(x)) for x ∈ ℛ,  of(x) for x ∈ ℬ
rsv(e, m)   ⟺ ∃b ∈ ℬ. of(b) = e ∧ reserves(b) ⊒ m
𝒜           = {sell, merge}                                     alienation: disposing of the owners' property
alien(m)    ⟺ ∃a ∈ 𝒜. a ⊒ m ∨ m ⊒ a
whole(e, p) ⟺ ∅ ≠ { h │ (h, e, _, _) ∈ Stake_t } = {p}
can(p, m)   ⟺ ∃(p, r) ∈ Seat_t. eff(r) ⊒ m ∧ ¬rsv(ent(r), m) ∧ (alien(m) ⟹ whole(ent(r), p))
comp(b, m)  ⟺ eff(b) ⊒ m ∧ (reserves(b) ⊒ m ∨ ¬rsv(of(b), m)) ∧ (alien(m) ⟹ members(b) = {:stake, _})
members(b)  = holders(R)                       if b selects {:seats, R}
            = { p | (p, of(b), c, _) ∈ Stake_t }  if b selects {:stake, c}
w_b(p)      = 1                                 per_capita
            = Σ{ n | (p, of(b), c, n) ∈ Stake_t }  {:units, c}
```

Decision of body `b` on matter `m` with votes `v : 𝒫 ⇀ {yes, no, abstain}`:

```
ultra_vires ⟺  ¬comp(b, m)                                  (checked first; `grants = []` ⇒ zero input)
v̂(p)        = ⌜decide(b₁, m, v)⌝, b₁ the head of voices(p, m)   if kind(p) = entity ∧ voices(p, m) ≠ ⟨⟩  (no fallback)
            = v(p)                                          otherwise (v(p) = ⊥ if p ∉ dom v)
              ⌜carried⌝ = yes, ⌜failed⌝ = no, else ⊥
W(S)        = Σ_{p ∈ S ∩ members(b)} w_b(p)
inquorate   ⟺  W(dom v̂) < q · W(members)
M_b(m)      = { p │ (p, b, G) ∈ Line_man,t ∧ G ⊒ m }               owners bound by mandate
ord         ⟺  ¬inquorate ∧ Y + N > 0 ∧ Y ⋈ θ·(Y + N)       Y = W(v̂⁻¹ yes), N = W(v̂⁻¹ no)
carried     ⟺  members ≠ ∅ ∧ ∀p ∈ members∖M. v̂(p) = yes ∧ (members ∩ M ≠ ∅ ⟹ ord)   if alien(m)
            ⟺  Y > 0                                          if dissolve ⊒ m ∧ tenure(class(b)) = revocable
            ⟺  ord                                            otherwise
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
| I11 | `classes` | `(of, name)` is unique over 𝒦 |
| I12 | `voices` | no two bodies of one entity hold ⊒-equivalent voices |
| I17 | `mandates` | `(p, b, _) ∈ Line_man,t ⟹ members(b) = {:stake, _} ∧ p ∈ members_t(b)` |
| I18 | `assets` | `quantity ∈ ℕ⁺`, `divisible ∈ 𝔹` (references by I1) |
| I16 | `alienation` | a body that reserves, or heads `voices(e, a)` for, some `a ∈ 𝒜` has `members = {:stake, _}` |
| I15 | `reserves` | `reserves(b) ⊆⊒ grants(b)` (decidable), and reservations of distinct bodies of one entity are pairwise ⊒-incomparable (uncontested) |

Temporal, ∀t:

| # | Name | Statement |
| --- | --- | --- |
| I6 | `reports_acyclic` | `Line_rep,t` is a DAG (matrix orgs allowed; loops not) |
| I7 | `delegation_acyclic` | `Line_del,t` is a DAG |
| I8 | `attenuation` | `(r, r', G) ∈ Line_del,t ⟹ ∀g ∈ G. eff(r) ⊒ g` |
| I9 | `seat_limits` | `|holders(r)| ≤ seats(r)` |
| I10 | `agent_accountability` | `kind(p) = agent ∧ (p, r) ∈ Seat_t ⟹ r →*_rep x` with some non-agent in `holders(x)` or `members(x)` |
| I13 | `eligibility` | `k ∈ 𝒦, employer(k) = e', (p, of(k), name(k), _) ∈ Stake_t ⟹ employs(e', p)` |
| I14 | `ownership_acyclic` | `{ (p, e) ∈ Stake_t │ kind(p) = entity }` is a DAG |

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

**Lemma (voice order is well-defined).** Every two capabilities covering a
common `m` are ⊒-comparable (case analysis on `m`: only `*` covers `*`; `k` is
covered by `*, k`; `(k, n)` by `*, k, (k, a ≥ n)` — each a chain). So the voices
of `e` covering `m` form a chain, totally ordered by specificity, and I12 removes
equivalent pairs across bodies. ∎

**Lemma (reservation is sound and live).** Under I15, for every reserved `m` of
`e` exactly one body `b` of `e` has `reserves(b) ⊒ m` (two would hold comparable
reservations), `comp(b, m)` holds (decidability), and `comp(b', m)` fails for
every other body `b'` of `e`, as does `can(p, m)` for every role of `e`. So a
reserved matter has exactly one decider: never none (deadlock), never two. ∎

**Lemma (look-through terminates).** Each recursive step moves from a body of
`e` to a member entity `p` with `(p, e) ∈ Stake_t`; under I14 that relation is
a finite DAG, so the recursion is well-founded. The implementation also carries
the set of visited entities, so even an org violating I14 decides (a revisited
entity is absent). ∎

Employee is deliberately minimal: `employs(e, p)` iff `p` holds *some* seat in a
role of `e` at `t`. A narrower notion (only roles marked as employment) would be
a refinement of `employs`, not a new primitive.

**Lemma (no alienation without full ownership).** If `alien(m)`, then
(i) a party acting alone can (`can(p, m)`) only when it is the sole holder of
every stake in the entity; (ii) a body carries `m` only when it is composed of
stakeholders and every unit of its eligible weight votes yes — at each level of
look-through, since an entity's yes is itself a full-consent carry of its most
specific voicing body, and a non-stake body is not competent (`comp`). Hence any
carried alienation is consented to by all ultimate owners. A trustee (seat-based)
can never supply that consent; I16 flags structures where only it could speak. ∎

## Ownership rights (`Keel.Ownership`)

Rights of an owner *qua* owner, independent of office. Each is a pure
`Org → Org` effective from `t`: current stakes are closed at `t` and successors
opened, so `σ_{t'}` is unchanged for `t' < t`.

```
withdraw(p, e, t)             defined ⟺ every class p holds in e is revocable
transfer(p, q, e, c, n, t)    defined ⟺ n ∈ ℕ⁺ ∧ n ≤ holding_t(p, e, c) ∧ ¬(I13 fails for q after)
  claimants = holders_t(e, c) ∖ {p}   if price given ∧ preemption(c) ∧ q ∉ holders_t(e, c)
            = ∅                       otherwise
preempt(sale, T)              defined ⟺ ∅ ≠ T ⊆ claimants ∧ ∀k ∈ T. H ∣ n·h_k
  each k ∈ T takes n·h_k / H from the buyer,  h_k = holding_t(k, e, c),  H = Σ_T h_k

partition(e, c, t)            h_p = holding_t(p, e, c),  H = Σ h_p
  allot(p, x) = ⌊q_x · h_p / H⌋        for divisible x ∈ 𝒳 of e  (in kind, qisma)
  sell(x)     = q_x − Σ_p allot(p, x)   (indivisible x: all of it; compelled sale)
  proceeds(p) = h_p / H                 (exact, reduced)
dissolve(b, v, c, t)          defined ⟺ decide(b, dissolve, v, t) = carried;
                              closes every stake in of(b) at t, returns partition(of(b), c, t)
```

Transfers consume the sender's current stakes soonest-expiring first; each moved
unit, and each remainder, keeps the end date of the stake it came from.

**Lemma (conservation).** `transfer` and `preempt` preserve `Σ_p holding_t(p, e, c)`
for every `t`; `withdraw` reduces it by exactly the withdrawer's holding. ∎

**Lemma (partition).** For every asset `x`: `Σ_p allot(p, x) + sell(x) = q_x`;
`allot(p, x) · H ≤ q_x · h_p < (allot(p, x) + 1) · H` (each owner receives the
floor of their exact share in kind); `Σ_p proceeds(p) = 1`. ∎

All four ownership lemmas are property-tested (`test/properties_test.exs`,
`test/partition_test.exs`, StreamData).

**Lemma (majority only by consent).** For `alien(m)`, an owner `p` who votes
other than yes can be outvoted only if `p ∈ M_b(m)`, i.e. only by `p`'s own
current, revocable mandate; and since `M_b(m)` is evaluated at `t`, a mandate
revoked before `t` restores `p`'s veto. With `M = ∅` the rule reduces to full
consent (A3). ∎

## Generalization: forms are configurations

| Form | Control | Economics | Executive answers to |
| --- | --- | --- | --- |
| Sole proprietorship | owners body, `{:units, :equity}`, one holder | same stake | owners |
| Partnership / LLC (*ʿinān*) | owners body, `{:units, :equity}`; equity revocable: any partner may withdraw or dissolve | same stake; own share transferable, optional pre-emption | owners |
| Corporation | shareholders `{:units, :common}` → board `{:seats, director}` per capita | `:common` | board |
| Consumer co-op | assembly `{:stake, :membership}` per capita | `:capital`, separate class | assembly |
| Worker co-op | as consumer co-op, with `:membership` employees-only (I13) | `:capital` | assembly |
| ESOP / EOT | owners body holds the trust; trust votes by look-through: beneficiaries voice alienation and reserved matters (full consent for alienation), trustee voices everything else | `:beneficial` in the trust, employees of the company only | board |
| Advisory board | `Body` with `grants: []` | — | decides nothing (`ultra_vires`) |
| Holding | subsidiary's owners body has an entity member | entity stake | composition of two corporations |
| Department | `Unit` under `hq`; head has no intrinsic grants | — | superior role, which delegates |
| Agent staff | agent `Party` seated in a role | — | I10: a chain ending in a non-agent |

Each row is a test in `test/forms_test.exs` or `test/employee_ownership_test.exs` that builds the form and asserts
`Invariants.check/1 == []`. One person holding several roles (owner-operator)
needs no special case: `Seat` is a relation, not a function.

## Amendments

Policies that were formally present but did not function, each with the
harmful outcome it permitted. Regression tests: `test/amendments_test.exs`.

| # | Previous policy | Harmful outcome | Amendment |
| --- | --- | --- | --- |
| A1 | Executive roles held `*`; bodies had no exclusive matters | Owner votes on a sale were decorative: the CEO could sell an employee-owned company unilaterally, and the board could approve it | `Body.reserves`; `can` and `comp` exclude matters reserved to another body. Corporations, partnerships and co-ops reserve `fundamental/0` (`sell, merge, dissolve, amend_charter`) to owners / members by default. Sole proprietorships reserve nothing (owner = executive) |
| A2 | An explicit vote recorded for an entity overrode look-through | Pass-through was bypassable: recording `trust: :yes` silenced the beneficiaries | An entity with a voicing body for the matter always votes by look-through; direct votes count only for entities outside the model |
| A3 | Sale, merger and dissolution followed ordinary majority-of-votes-cast rules; an interim amendment let the trustee vote when beneficiaries were inquorate | Owners who did not fully own could dispose of the whole: a 51% partner could sell, a quorum-plus-one of co-op members could dissolve, a trustee (title holder, not owner) could sell an employee-owned company | **No one sells what they do not fully own.** Alienation (`sell, merge, dissolve`) carries only with the consent of the entire ownership — an absent or abstaining owner is a refusal, so owner-employees must engage. Only stakeholder bodies are competent; a role may alienate only if its holder owns the entity outright. Look-through has no fallback. Invariant I16 |
| A3′ | Dissolution was treated as alienation (full consent) | One partner could hold the others in a partnership indefinitely; no owner could exit or dispose of their own share without everyone | `dissolve ∉ 𝒜`. Revocable classes: any holder may withdraw or dissolve. Each owner may transfer their own units (`Ownership.transfer/8`), subject to eligibility and optional pre-emption. A majority may bind an owner on alienation only through that owner's revocable mandate (I17) |
| A4 | `Body.grants` defaulted to `*` | Any body declared ad hoc was plenary (fail-open) | Default `[]` (fail-closed); authority must be granted |
| A5 | — (new with A1) | A reservation its body cannot decide is a permanent deadlock; two bodies reserving overlapping matters contest authority | Invariant I15 |

## Scope

In: who exists, who holds what position, who answers to whom, who may do what,
who owns what, and how groups decide. Out (by design, belongs elsewhere):
money movements and ledgers, workflows and tasks, documents and files,
contracts between entities. Those systems reference Keel ids rather than
re-encode structure.
