# Keel company primitives — specification v1

**Status:** normative. It describes `apps/keel` as of this revision: 84 tests and 8 properties, all passing.
**Companion:** [`PRIMITIVES.md`](PRIMITIVES.md) is non-normative and holds the formal
model's rationale, the soundness lemmas with their proofs, and the amendment record (A1–A5).
This document is the contract. It says what any implementation of Keel must do, the
Elixir reference or a port such as the `larsbx/keel` polyglot migration, so that it
agrees with every other.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.
`⊒` is capability covering (§3), `σ_t` the snapshot at `t` (§2), and `⊥` absence.

## 0. Conformance

An implementation conforms when, for every org `O` and instant `t`:

- **C1.** It accepts exactly the values of §1 and builds `O` as §1.3 says.
- **C2.** Every query of §4 returns the same value as the reference, up to the order of sets.
- **C3.** `decide` (§5) returns the same outcome and tally.
- **C4.** `check` (§6) returns the same set of violations, compared by `(name, detail)` with the earliest `t`.
- **C5.** Every operation of §7 returns the same result, or the same error atom.
- **C6.** Every form of §8 builds the same set of primitives.

The reference test suite (`apps/keel/test`) is the conformance suite. A port MUST pass it,
translated case by case, and MUST NOT weaken any assertion.

Everything is pure and immutable. No operation mutates an org or reads a clock, and
history is never rewritten: change is a new interval (§2, §7).

## 1. Data model

### 1.1 Nodes

Every node has an `id`, which may be any term. Ids share one namespace across all node sorts.

| Sort | Fields (default) | Domain |
| --- | --- | --- |
| `Party` | `id`, `kind`, `name` (`nil`) | `kind ∈ {person, entity, agent}`; `𝒫ₑ ≔ {p │ kind(p) = entity}` |
| `Unit` | `id`, `of`, `parent` (`nil`), `kind` (`:unit`), `name` (`nil`) | `of ∈ 𝒫ₑ`; `parent ∈ Unit ∪ {nil}`; `kind` is a free label |
| `Role` | `id`, `unit`, `grants` (`[]`), `seats` (`:any`), `name` (`nil`) | `unit ∈ Unit`; `grants ⊆ 𝒞`; `seats ∈ ℕ ∪ {:any}` |
| `Body` | `id`, `of`, `members`, `weight` (`:per_capita`), `quorum` (`{1, 2}`), `pass` (`{:gt, {1, 2}}`), `grants` (`[]`), `reserves` (`[]`), `voices` (`[]`) | `of ∈ 𝒫ₑ`; `members ∈ {{:seats, [Role]}, {:stake, class}}`; `weight ∈ {:per_capita, {:units, class}}`; `quorum = {n, d} ∈ ℚ`; `pass = {⋈, {n, d}}`, `⋈ ∈ {:gt, :ge}`; `grants, reserves, voices ⊆ 𝒞` |
| `Class` | `id`, `of`, `name`, `eligible` (`:any`), `tenure` (`:binding`), `preemption` (`false`) | `eligible ∈ {:any, :employees, {:employees, e ∈ 𝒫ₑ}}`; `tenure ∈ {:binding, :revocable}`; `preemption ∈ 𝔹` |
| `Asset` | `id`, `of`, `quantity` (`1`), `divisible` (`false`), `name` (`nil`) | `of ∈ 𝒫ₑ`; `quantity ∈ ℕ⁺`; `divisible ∈ 𝔹` |

`employer : Class ⇀ 𝒫ₑ` is `of` when `eligible = :employees`, `e` when it is
`{:employees, e}`, and undefined otherwise.

A stake class `c` of entity `e` that has no `Class` node with `(of, name) = (e, c)` is
unrestricted: eligible to anyone, binding, and with no pre-emption.

### 1.2 Edges

Edges carry `during : Interval` (default: always) and have no id.

| Sort | Fields (default) | Meaning |
| --- | --- | --- |
| `Seat` | `party`, `role` | `party ∈ Party` holds `role ∈ Role` |
| `Line` | `from`, `to`, `kind` (`:reports`), `grants` (`[]`) | `kind = :reports`: `from ∈ Role` answers to `to ∈ Role ∪ Body`. `kind = :delegates`: `from ∈ Role ∪ Body` confers `grants` on `to ∈ Role ∪ Body`. `kind = :mandates`: owner `from ∈ Party` authorizes body `to ∈ Body` to decide `grants` on their behalf by its ordinary rule |
| `Stake` | `holder`, `in`, `class` (`:equity`), `units` (`1`) | `holder ∈ Party` holds `units ∈ ℕ⁺` of `class` in `in ∈ 𝒫ₑ` |

### 1.3 Org

`Org = (nodes : id ↦ node, edges : [edge])`.

- `new(items)` takes a list of primitives, which may be nested, flattens it and adds every item in order.
- Adding a node whose id already exists MUST fail with `ArgumentError`: duplicate ids are a construction error, not a violation.
- Edges MAY repeat.
- Referential integrity is not enforced at construction. It is reported by `check` (I1).

## 2. Time

`𝕋` is the set of calendar dates, totally ordered. An interval `[a, b)` is half-open,
and a bound of `nil` is unbounded (`a = nil` means −∞, `b = nil` means +∞).

```
contains([a, b), t)  ⟺  (a = nil ∨ a ≤ t) ∧ (b = nil ∨ t < b)
well_formed([a, b))  ⟺  a = nil ∨ b = nil ∨ a < b
bounds([a, b))        =  {a, b} ∖ {nil}
```

- **Snapshot.** `edges(O, S, t) = {x ∈ edges(O) │ x : S ∧ contains(during(x), t)}`, and `σ_t` is the org restricted to those edges.
- **Epochs.** `epochs(O) = sort(uniq({origin} ∪ ⋃ₓ bounds(during(x))))`, with `origin = −9999-01-01`.

`σ_t` is constant on `[eᵢ, eᵢ₊₁)` (the epochs lemma in PRIMITIVES.md), so evaluating a
temporal predicate at every epoch decides it for all `t ≥ origin`.

## 3. Capabilities

```
𝒞  ::=  *  │  k  │  (k, n)          k an atom, n a number
* ⊒ c        k ⊒ k        k ⊒ (k, n)        (k, a) ⊒ (k, b) ⟺ a ≥ b        nothing else
H ⊒ c  ⟺  ∃h ∈ H. h ⊒ c                                                  (covered?)
```

`⊒` is a preorder: reflexive and transitive.

- **Alienation set.** `𝒜 = {sell, merge}`.
- **alien.** `alien(m) ⟺ ∃a ∈ 𝒜. a ⊒ m ∨ m ⊒ a`. Hence `alien(*)` holds: a plenary matter includes sale.
- **Dissolution is not alienation.** `dissolve ∉ 𝒜` (A3′); it has its own rule (§5.3).

## 4. Queries

Every query is a function of `(O, t)`. Results that are sets MAY come in any order, with
one exception: `voices`, whose order is part of the result.

| Query | Definition |
| --- | --- |
| `holders(r, t)` | `{p │ (p, r) ∈ Seat_t}` |
| `roles(p, t)` | `{r │ (p, r) ∈ Seat_t}` |
| `effective(x, t)` | `grants(x) ∪ ⋃{G │ (_, x, G) ∈ Line_del,t}`, for `x ∈ Role ∪ Body` |
| `entity_of(x)` | `of(unit(x))` for a role, `of(x)` for a body |
| `employs(e, p, t)` | `∃r ∈ roles(p, t). of(unit(r)) = e` |
| `voices(e, m)` | the bodies `b` of `e` having some `v ∈ voices(b)` with `v ⊒ m`, sorted most specific `v` first and deduplicated. Time-independent |
| `class(e, c)` | the `Class` with `(of, name) = (e, c)`, or `⊥` |
| `holding(p, e, c, t)` | `Σ{n │ (p, e, c, n) ∈ Stake_t}` |
| `reserved(e, m)` | `∃b ∈ Body. of(b) = e ∧ reserves(b) ⊒ m` |
| `owns_all(e, p, t)` | `∅ ≠ {h │ (h, e, _, _) ∈ Stake_t} = {p}` |
| `capabilities(p, t)` | `⋃{effective(r, t) │ r ∈ roles(p, t)}`: raw, before reservation |
| `can(p, m, t)` | `∃r ∈ roles(p, t). effective(r, t) ⊒ m ∧ ¬reserved(entity_of(r), m) ∧ (alien(m) ⟹ owns_all(entity_of(r), p, t))` |
| `competent(b, m, t)` | `effective(b, t) ⊒ m ∧ (reserves(b) ⊒ m ∨ ¬reserved(of(b), m)) ∧ (alien(m) ⟹ members(b) = {:stake, _})` |
| `members(b, t)` | eligible parties mapped to their weights: `{:seats, R}` gives `⋃{holders(r, t) │ r ∈ R}`, and `{:stake, c}` gives `{h │ (h, of(b), c, _) ∈ Stake_t}`. The weight is `1` for `:per_capita`, or `holding(p, of(b), c', t)` for `{:units, c'}` |

## 5. Decision

`decide(O, b, m, v, t)` takes `v : Party ⇀ {yes, no, abstain}`. It returns
`{ultra_vires, ⊥}` or `{o, tally}`, with `o ∈ {carried, failed, inquorate}` and
`tally = (eligible, present, yes, no) ∈ ℕ⁴`. Arithmetic MUST be exact; the reference
cross-multiplies integers.

### 5.1 Competence

If `¬competent(b, m, t)`, the result is `{ultra_vires, ⊥}`. This is checked first, and nothing else is evaluated.

### 5.2 Cast

For each `(p, w) ∈ members(b, t)`, a cast `v̂(p)` is computed:

```
v̂(p) = verdict(decide(O, b₁, m, v, t))   if kind(p) = entity ∧ voices(p, m) = ⟨b₁, …⟩ ∧ p ∉ seen
     = ⊥                                  if kind(p) = entity ∧ voices(p, m) ≠ ⟨⟩ ∧ p ∈ seen
     = v(p)                               otherwise (⊥ if p ∉ dom v)
verdict(carried) = yes    verdict(failed) = no    verdict(_) = ⊥
```

- **Seen set.** `seen` starts as `{of(b)}` and grows by `p` on each recursion, so look-through terminates even on an org that violates I14.
- **No fallback.** An entity with a voicing body never votes directly: an entry `v(p)` is ignored.
- **Single voicing body.** Only `b₁` is consulted. A non-carrying `b₁` does not fall back to a more general voice.
- **Non-members.** Votes from non-members are ignored.

With `W(P) = Σ_{p ∈ P} w(p)`:

```
eligible = W(members)    present = W({p │ v̂(p) ≠ ⊥})    yes = W(v̂⁻¹ yes)    no = W(v̂⁻¹ no)
```

`abstain` counts as present but is neither yes nor no.

### 5.3 Outcome

With quorum `{qn, qd}` and pass `{⋈, {n, d}}`:

```
ordinary = inquorate   if present·qd < qn·eligible
         = carried     if yes + no > 0 ∧ yes·d ⋈ n·(yes + no)
         = failed      otherwise

M = {p │ (p, b, G) ∈ Line_man,t ∧ G ⊒ m}                   owners bound by mandate

o = consent            if alien(m)
  = (yes > 0 ? carried : failed)
                       if dissolve ⊒ m ∧ members(b) = {:stake, c} ∧ tenure(class(of(b), c)) = revocable
  = ordinary           otherwise

consent = failed       if members = ∅
        = failed       if ∃p ∈ members ∖ M. v̂(p) ≠ yes      (absence and abstention refuse)
        = ordinary     if members ∩ M ≠ ∅
        = carried      otherwise
```

The tally is always reported, whatever `o` is.

## 6. Invariants

- **Result.** `check(O)` returns a list of violations `(name, t, detail)`. `t = nil` marks a static check; otherwise `t` is the epoch at which the violation was found.
- **Deduplication.** Violations are deduplicated by `(name, detail)`, keeping the earliest `t`: static violations first, then temporal ones in epoch order.
- **Validity.** `valid?(O) ⟺ check(O) = []`.

Static invariants are evaluated once:

| # | `name` | Violation when | `detail` |
| --- | --- | --- | --- |
| I1 | `references` | a reference does not resolve to a node of the required sort: `of`, `in` and `employer` must be in `𝒫ₑ`, other references per §1 | `{:dangling, at, id, sort}` |
| I2 | `kinds` | the party kind, line kind, body shape (`members` and `weight`) or class shape (`eligible`, `tenure`, `preemption`) is outside its enumeration | `{:party_kind \| :line_kind \| :body_shape \| :class_shape, x}` |
| I3 | `intervals` | `¬well_formed(during(x))` | `{:empty, x}` |
| I4 | `stakes` | `units ∉ ℕ⁺` | `{:units, s}` |
| I5 | `unit_forest` | `parent` has a cycle, or `of(parent(u)) ≠ of(u)` | `{:cycle, path}`, `{:cross_entity, u, p}` |
| I11 | `classes` | two classes share `(of, name)` | `{:duplicate, {e, name}}` |
| I12 | `voices` | two bodies of one entity hold voices `v, w` with `v ⊒ w ∧ w ⊒ v` | `{:clash, e, b₁, b₂, v}` |
| I15 | `reserves` | some `r ∈ reserves(b)` has `¬(grants(b) ⊒ r)` (undecidable), or two bodies of one entity reserve ⊒-comparable matters (contested) | `{:undecidable, b, r}`, `{:contested, e, b₁, b₂, v, w}` |
| I16 | `alienation` | a body that reserves some `a ∈ 𝒜`, or heads `voices(e, a)`, is not `{:stake, _}` | `{:non_owner, b, a}` |
| I18 | `assets` | `quantity ∉ ℕ⁺` or `divisible ∉ 𝔹` | `{:shape, x}` |

Temporal invariants are evaluated at every `t ∈ epochs(O)`:

| # | `name` | Violation when | `detail` |
| --- | --- | --- | --- |
| I6 | `reports_acyclic` | `Line_rep,t` has a cycle | `{:cycle, path}` |
| I7 | `delegation_acyclic` | `Line_del,t` has a cycle | `{:cycle, path}` |
| I8 | `attenuation` | `(f, x, G) ∈ Line_del,t` with some `g ∈ G` such that `¬(effective(f, t) ⊒ g)` | `{:exceeds, f, x, g}` |
| I9 | `seat_limits` | `seats(r) ∈ ℕ ∧ │holders(r, t)│ > seats(r)` | `{:oversubscribed, r, k, n}` |
| I10 | `agent_accountability` | an agent holds `r` and no `x` with `r →*_rep x` has a non-agent among `holders(x)` or `members(x)` | `{:unaccountable, p, r}` |
| I13 | `eligibility` | `(h, of(k), name(k), _) ∈ Stake_t ∧ employer(k) = e' ∧ ¬employs(e', h, t)` | `{:ineligible, h, e, c}` |
| I14 | `ownership_acyclic` | the entity-held stakes `{(h, e) │ kind(h) = entity}` have a cycle at `t` | `{:cycle, path}` |
| I17 | `mandates` | a mandate `(p, b, _)` at `t` where `b` is not `{:stake, _}`, or `p ∉ members(b, t)` | `{:not_owner, p, b}` |

**Cycle detail.** A cycle is reported as one closed path `[v, …, v]`, at most one per
check and epoch. Which cycle is reported MAY differ between implementations. A conforming
port MUST agree on whether some cycle exists, and SHOULD report a minimal one.

The numbering follows the order in which the invariants were introduced; `names()` lists
the static ones first, then the temporal ones.

## 7. Ownership operations

Each operation is a pure `Org → Org` effective from `t`. Edges whose interval contains `t`
are closed at `t` and successors are opened, so `σ_{t'}` is unchanged for every `t' < t`.

### 7.1 `move` (internal; defines every stake change)

`move(from, to, e, c, n, t)` takes `n ≤ holding(from, e, c, t)` and `to ∈ Party ∪ {nil}`,
where `nil` relinquishes the units. It consumes `from`'s current stakes of `(e, c)` in
order of soonest expiry, with an unbounded end last. For each consumed stake
`s = (from, e, c, u, [a, b))`, taking `k = min(left, u)`:

- **Before `t`.** If `a = nil ∨ a < t`, keep `(from, e, c, u, [a, t))`.
- **Remainder.** If `u > k`, add `(from, e, c, u − k, [t, b))`.
- **Moved units.** If `to ≠ nil ∧ k > 0`, add `(to, e, c, k, [t, b))`.

Moved units and remainders keep the end date `b` of the stake they came from.

### 7.2 Operations

| Operation | Errors, checked in this order | Effect |
| --- | --- | --- |
| `withdraw(p, e, t)` | `:not_owner` if `p` holds no class in `e` at `t`; `:binding` unless every such class is revocable | `move(p, nil, e, c, holding, t)` for each class `c` |
| `transfer(p, q, e, c, n, t, price?)` | `:units` unless `n ∈ ℕ⁺`; `{:insufficient, held}` if `holding < n`; `:ineligible` if, after the move, `{:ineligible, q, e, c} ∈ I13(t)` | `move(p, q, e, c, n, t)`; returns `Transfer(from, to, in, class, units, at, price, claimants)` |
| `preempt(O, T, takers)` | `:not_entitled` if `takers = ∅` or `takers ⊄ claimants(T)`; `:indivisible` if some `k` has `H ∤ n·h_k` | each `k` takes `n·h_k / H` from the buyer by `transfer`. Here `h_k = holding(k, e, c, t)` in the given `O`, and `H = Σ h_k` |
| `partition(e, c, t)` | none | a `Partition` record: see below |
| `dissolve(b, v, c, t)` | `:not_carried` unless `decide(b, dissolve, v, t) = carried` | closes every stake in `of(b)` at `t`, and returns `partition(of(b), c, t)` computed on the org before closing |

**Transfer details.**
- `claimants = holders(e, c, t) ∖ {p}` when `price ≠ nil`, `c` is pre-emptive and `q` is not among those co-holders. Otherwise `claimants = ∅`.
- No consent from other owners is needed: an owner disposes of their own share.
- Transferring to yourself is unspecified; callers SHOULD NOT do it.

**Partition record.** For holders `h_p = holding(p, e, c, t)` and `H = Σ h_p`, over the assets `x` of `e`, ordered by id:

- **Divisible assets.** `allot(p, x) = ⌊q_x·h_p / H⌋` for `x.divisible`, and only when `H > 0`. Zero allotments are omitted.
- **Sold remainder.** `sell(x) = q_x − Σ_p allot(p, x)`, omitted when it is 0. An indivisible asset is sold whole.
- **Proceeds.** `proceeds(p) = h_p / H`, as a reduced fraction.

Conservation and exactness are stated in PRIMITIVES.md and property-tested.

## 8. Forms

Forms build structure, not people: the caller declares the `Party` nodes. Ids are
namespaced by entity, as `{e, :hq}`, `{e, role}`, `{e, :class, name}` and `{e, d, :head}`,
so forms compose by list concatenation. `fundamental = [sell, merge, dissolve, amend_charter]`.

| Form | MUST produce |
| --- | --- |
| `entity(e)` | `Party(e, entity)`; `Unit({e, :hq}, of: e, kind: :entity)` |
| `owners(e, H, c = :equity, R = fundamental)` | `Body({e, :owners}, {:stake, c}, {:units, c}, grants [*], reserves R)`; one `Stake` per `(p, n) ∈ H` |
| `executive(e, r, P, sup, seats = :any)` | `Role({e, r}, {e, :hq}, [*], seats)`; `Line({e, r} → sup, :reports)`; a `Seat` for each `p ∈ P` |
| `sole_proprietorship(e, o)` | `entity` + `owners(e, [(o, 1)], :equity, [])` + `executive(e, :principal, [o], {e, :owners}, 1)` |
| `partnership(e, H, managers?, preemption? = false)` | `entity` + `owners(e, H)` + `Class({e, :class, :equity}, tenure revocable, preemption)` + `executive(e, :manager, managers ∨ partners, {e, :owners})` |
| `corporation(e, H, D, ceo)` | `entity` + `owners(e, H, :common)` + `Role({e, :director}, grants [govern], seats │D│)` reporting to `{e, :owners}` + `Body({e, :board}, {:seats, [{e, :director}]}, grants [*])` + director seats + `executive(e, :ceo, [ceo], {e, :board}, 1)` |
| `cooperative(e, M, mgr, capital? = %{})` | `entity` + `Body({e, :assembly}, {:stake, :membership}, per capita, grants [*], reserves fundamental)` + one `:membership` stake per member + `:capital` stakes + `executive(e, :manager, [mgr], {e, :assembly}, 1)` |
| `worker_cooperative(e, M, mgr, capital?)` | `cooperative` + `Class({e, :class, :membership}, eligible :employees)` + `Role({e, :worker})` + a worker seat for each member |
| `employee_trust(tr, co, trustee, A, R, weight = {:units, :beneficial})` | `entity(tr)` + `Class(:beneficial, eligible {:employees, co})` + `Role({tr, :trustee}, [administer], 1)` seated by `trustee` + `Body({tr, :trustees}, {:seats, [trustee role]}, grants [*], voices [*])` + `Body({tr, :beneficiaries}, {:stake, :beneficial}, weight, grants = voices = 𝒜 ∪ R)` + allocation stakes |
| `department(e, d, sup, G)` | `Unit({e, d}, parent {e, :hq}, kind :department)` + `Role({e, d, :head}, seats 1)` + a `:reports` line and a `:delegates` line with `G` from `sup` |

Every form, as the tests instantiate it, satisfies `check = []`.

## 9. Known gaps (normative status: unspecified)

These behaviours are reproduced in the reference implementation but not yet constrained.
A port MUST match the reference on the valid orgs the suite covers, and MAY reject what is
listed here as an extension, as long as it documents doing so.

| # | Gap | Consequence |
| --- | --- | --- |
| G1 | I2 does not check `Role.seats ∈ ℕ ∪ {:any}`, `Body.quorum` or `Body.pass` | `check` accepts, for example, `seats: :two` or `quorum: :bad`. A non-integer `seats` is then treated as unbounded (I9 skips it), and a malformed `quorum` or `pass` makes `decide` fail at run time |
| G2 | `seats: 0` is valid and means the role can never be held | likely unintended; SHOULD become `ℕ⁺ ∪ {:any}` |
| G3 | `alien(*)` holds, so a body deciding the matter `*` follows the alienation rule | intended (a plenary matter includes sale), but surprising; callers SHOULD decide specific matters |
| G4 | `Ownership`'s moduledoc says the stakes it opens are open-ended; §7.1 (the code) keeps the source stake's end | the moduledoc is stale; §7.1 is normative |
| G5 | Dates before `origin` (−9999-01-01) fall outside the epoch argument | not reachable through `Date` in practice |
| G6 | Transferring to yourself (`p = q`) | unspecified (§7.2) |

## 10. Planned extensions (non-normative)

These come from the 2026-10-20 primitive audit (`docs/architecture/2026-10-20-primitive-audit.md`,
"What Keel lacks"). None is specified yet. Each would be a v2 change and would come with tests.

- **Seat scope:** narrowing a role's grants to a subject (`self`, `org`, a load, an assignment).
- **Seat minimum:** `Role.seats : {min, max}`, with `min ≤ │holders│ ≤ max` and last-holder protection.
- **Separation of duties:** the actor may not be the subject or the proposer.
- **Single-use, expiring permits:** a `:delegates` line with a use count and an interval.
- **Versioned role definitions:** a seat names the version it holds.
- **Membership lifecycle:** probation, cure, hardship and estate, as class states that govern eligibility.
- **`Party.kind = :system`:** together with a decision on whether it counts as accountable for I10.
- **Founding-party invariant:** the root seat is held by a person.
