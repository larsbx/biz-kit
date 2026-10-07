# Nodes — identified by a globally unique `id` (any term; forms use tuples as namespaces).

defmodule Keel.Party do
  @moduledoc "Anything that can hold a seat or a stake. `kind ∈ {:person, :entity, :agent}`."
  @kinds [:person, :entity, :agent]
  defstruct [:id, :kind, name: nil]
  def kinds, do: @kinds
end

defmodule Keel.Unit do
  @moduledoc "An organizational container of entity `of`; `parent` units form a forest."
  defstruct [:id, :of, parent: nil, kind: :unit, name: nil]
end

defmodule Keel.Role do
  @moduledoc "A position within a unit: intrinsic `grants`, at most `seats` holders (`:any` = unbounded)."
  defstruct [:id, :unit, grants: [], seats: :any, name: nil]
end

defmodule Keel.Class do
  @moduledoc """
  A stake class `name` of entity `of`, with an eligibility rule:
  `:any` | `:employees` (of `of`) | `{:employees, entity}`. Stakes of a class with
  no `Class` node are unrestricted.
  """
  defstruct [:id, :of, :name, eligible: :any]

  def employer(%__MODULE__{eligible: :employees, of: e}), do: e
  def employer(%__MODULE__{eligible: {:employees, e}}), do: e
  def employer(%__MODULE__{}), do: nil
end

defmodule Keel.Body do
  @moduledoc """
  A collective decision-maker of entity `of`.

    * `members`  — `{:seats, [role_id]}` (holders of those roles) | `{:stake, class}` (holders of that class)
    * `weight`   — `:per_capita` | `{:units, class}`
    * `quorum`   — `{n, d}`: present weight / eligible weight ≥ n/d
    * `pass`     — `{:gt | :ge, {n, d}}` over weight cast yes / (yes + no)
    * `grants`   — matters it may decide; fail-closed (`[]`, advisory) unless granted; may delegate like a role
    * `reserves` — matters of its entity that *only* this body may decide; no role may exercise them
    * `voices`   — matters on which this body casts its entity's vote elsewhere (look-through);
      the most specific voice that reaches a decision wins
  """
  @weights [:per_capita]
  defstruct [
    :id,
    :of,
    :members,
    weight: :per_capita,
    quorum: {1, 2},
    pass: {:gt, {1, 2}},
    grants: [],
    reserves: [],
    voices: []
  ]

  def weight?(w), do: w in @weights or match?({:units, _}, w)
end

# Edges — temporal facts, valid over `during`.

defmodule Keel.Seat do
  @moduledoc "Party `party` holds role `role`."
  defstruct [:party, :role, during: %Keel.Interval{}]
end

defmodule Keel.Line do
  @moduledoc """
  A directed relation between roles and bodies.

    * `:reports`   — role `from` answers to `to` (a role or a body)
    * `:delegates` — `from` confers `grants` on `to` (each a role or a body); must attenuate
  """
  @kinds [:reports, :delegates]
  defstruct [:from, :to, kind: :reports, grants: [], during: %Keel.Interval{}]
  def kinds, do: @kinds
end

defmodule Keel.Stake do
  @moduledoc "Party `holder` holds `units ∈ ℕ⁺` of `class` in entity `in` (equity, membership, capital, …)."
  defstruct [:holder, :in, class: :equity, units: 1, during: %Keel.Interval{}]
end
