defmodule Keel.Capability do
  @moduledoc """
  Capabilities and their covering preorder `⊒`.

      :*            ⊒ c            (plenary authority)
      k             ⊒ k, {k, n}    (unbounded k)
      {k, a}        ⊒ {k, b}  iff a ≥ b
  """

  @type t :: :* | atom | {atom, number}

  def covers?(:*, _), do: true
  def covers?(k, k), do: true
  def covers?(k, {k, _}) when is_atom(k), do: true
  def covers?({k, a}, {k, b}), do: a >= b
  def covers?(_, _), do: false

  @doc "`need` is covered by some capability in `have`."
  def covered?(have, need), do: Enum.any?(have, &covers?(&1, need))

  @alienation [:sell, :merge, :dissolve]

  @doc "Matters that dispose of the owners' property: only the whole ownership may decide them."
  def alienation, do: @alienation

  @doc "`c` is, or includes, an alienation matter."
  def alienating?(c), do: Enum.any?(@alienation, &(covers?(&1, c) or covers?(c, &1)))
end
