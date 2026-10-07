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

defmodule Keel.Body do
  @moduledoc """
  A collective decision-maker of entity `of`.

    * `members` — `{:seats, [role_id]}` (holders of those roles) | `{:stake, class}` (holders of that class)
    * `weight`  — `:per_capita` | `{:units, class}`
    * `quorum`  — `{n, d}`: present weight / eligible weight ≥ n/d
    * `pass`    — `{:gt | :ge, {n, d}}` over weight cast yes / (yes + no)
  """
  @weights [:per_capita]
  defstruct [:id, :of, :members, weight: :per_capita, quorum: {1, 2}, pass: {:gt, {1, 2}}]
  def weight?(w), do: w in @weights or match?({:units, _}, w)
end

# Edges — temporal facts, valid over `during`.

defmodule Keel.Seat do
  @moduledoc "Party `party` holds role `role`."
  defstruct [:party, :role, during: %Keel.Interval{}]
end

defmodule Keel.Line do
  @moduledoc """
  A directed relation between roles.

    * `:reports`   — `from` answers to `to` (a role or a body)
    * `:delegates` — `from` confers `grants` on `to`; must attenuate
  """
  @kinds [:reports, :delegates]
  defstruct [:from, :to, kind: :reports, grants: [], during: %Keel.Interval{}]
  def kinds, do: @kinds
end

defmodule Keel.Stake do
  @moduledoc "Party `holder` holds `units ∈ ℕ⁺` of `class` in entity `in` (equity, membership, capital, …)."
  defstruct [:holder, :in, class: :equity, units: 1, during: %Keel.Interval{}]
end
