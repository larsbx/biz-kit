defmodule Keel.Org do
  @moduledoc """
  An organization: an immutable graph of nodes (`Party`, `Unit`, `Role`, `Body`, `Class`),
  keyed by globally unique id, and temporal edges (`Seat`, `Line`, `Stake`).

  All queries are pure functions of `(org, t)` — the snapshot at instant `t`.
  """
  alias Keel.{Body, Capability, Class, Interval, Line, Party, Role, Seat, Stake, Unit}

  @nodes [Party, Unit, Role, Body, Class]
  @edges [Seat, Line, Stake]
  @origin Date.new!(-9999, 1, 1)

  defstruct nodes: %{}, edges: []
  @type t :: %__MODULE__{nodes: %{term => struct}, edges: [struct]}

  @doc "Build from a (possibly nested) list of primitives."
  def new(items \\ []), do: items |> List.flatten() |> Enum.reduce(%__MODULE__{}, &put(&2, &1))

  def put(%__MODULE__{nodes: nodes} = org, %mod{id: id} = node) when mod in @nodes do
    if Map.has_key?(nodes, id), do: raise(ArgumentError, "duplicate id #{inspect(id)}")
    %{org | nodes: Map.put(nodes, id, node)}
  end

  def put(%__MODULE__{edges: edges} = org, %mod{} = edge) when mod in @edges,
    do: %{org | edges: [edge | edges]}

  def get(org, id), do: Map.get(org.nodes, id)
  def nodes(org, mod), do: for(%{__struct__: ^mod} = n <- Map.values(org.nodes), do: n)
  def edges(org, mod), do: for(%{__struct__: ^mod} = e <- org.edges, do: e)
  def edges(org, mod, t), do: for(e <- edges(org, mod), Interval.contains?(e.during, t), do: e)

  @doc "Instants at which any snapshot may change; checking these suffices for all `t`."
  def epochs(org),
    do:
      [@origin | Enum.flat_map(org.edges, &Interval.bounds(&1.during))]
      |> Enum.uniq()
      |> Enum.sort(Date)

  def holders(org, role, t),
    do: for(%Seat{role: ^role, party: p} <- edges(org, Seat, t), uniq: true, do: p)

  def roles(org, party, t),
    do: for(%Seat{party: ^party, role: r} <- edges(org, Seat, t), uniq: true, do: r)

  @doc "`{from, to}` pairs of lines of `kind` active at `t`."
  def graph(org, kind, t),
    do: for(%Line{kind: ^kind, from: f, to: to} <- edges(org, Line, t), do: {f, to})

  @doc "Intrinsic grants of a role or body plus everything delegated to it at `t`."
  def effective(org, id, t) do
    delegated =
      for %Line{kind: :delegates, to: ^id, grants: gs} <- edges(org, Line, t), g <- gs, do: g

    Enum.uniq(get(org, id).grants ++ delegated)
  end

  @doc "`p` holds a seat in some role of entity `e` at `t`."
  def employs?(org, e, p, t),
    do: Enum.any?(roles(org, p, t), &match?(%Unit{of: ^e}, get(org, get(org, &1).unit)))

  @doc "Bodies of entity `e` voicing `matter`, most specific first (a chain, by I12)."
  def voices(org, e, matter) do
    for(
      %Body{of: ^e, id: b, voices: vs} <- nodes(org, Body),
      v <- vs,
      Capability.covers?(v, matter),
      do: {b, v}
    )
    |> Enum.sort(fn {_, v}, {_, w} -> Capability.covers?(w, v) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
  end

  @doc "The `Class` node for stake class `name` of entity `e`, or `nil`."
  def class(org, e, name),
    do: Enum.find(nodes(org, Class), &(&1.of == e and &1.name == name))

  @doc "Units of `class` in entity `e` held by `p` at `t`."
  def holding(org, p, e, class, t),
    do:
      Enum.sum(
        for %Stake{holder: ^p, in: ^e, class: ^class, units: u} <- edges(org, Stake, t), do: u
      )

  @doc "The entity a role or body acts for."
  def entity_of(org, id) do
    case get(org, id) do
      %Role{unit: u} -> get(org, u).of
      %Body{of: e} -> e
    end
  end

  @doc "`matter` is reserved to some body of entity `e`."
  def reserved?(org, e, matter),
    do: Enum.any?(nodes(org, Body), &(&1.of == e and Capability.covered?(&1.reserves, matter)))

  @doc """
  Body `b` may decide `matter` at `t`: within its grants, not reserved to another
  body, and — for alienation — composed of the owners themselves (`{:stake, _}`).
  """
  def competent?(org, %Body{id: id, of: e, reserves: rs, members: m}, matter, t),
    do:
      Capability.covered?(effective(org, id, t), matter) and
        (Capability.covered?(rs, matter) or not reserved?(org, e, matter)) and
        (match?({:stake, _}, m) or not Capability.alienating?(matter))

  @doc "`p` holds every stake in entity `e` at `t` (and there is at least one)."
  def owns_all?(org, e, p, t) do
    holders = for %Stake{in: ^e, holder: h} <- edges(org, Stake, t), do: h
    holders != [] and Enum.all?(holders, &(&1 == p))
  end

  @doc "Raw capabilities from seats and delegation, before reservations (see `can?/4`)."
  def capabilities(org, party, t),
    do: org |> roles(party, t) |> Enum.flat_map(&effective(org, &1, t)) |> Enum.uniq()

  @doc """
  Some role `party` holds covers `need`, `need` is not reserved to a body of that
  role's entity, and — for alienation — `party` owns that entity outright.
  """
  def can?(org, party, need, t) do
    Enum.any?(roles(org, party, t), fn r ->
      e = entity_of(org, r)

      Capability.covered?(effective(org, r, t), need) and not reserved?(org, e, need) and
        (owns_all?(org, e, party, t) or not Capability.alienating?(need))
    end)
  end

  @doc "Eligible members of a body at `t`, mapped to their voting weight."
  def members(org, %Body{of: e, members: sel, weight: w}, t) do
    eligible =
      case sel do
        {:seats, roles} ->
          Enum.flat_map(roles, &holders(org, &1, t))

        {:stake, class} ->
          for %Stake{in: ^e, class: ^class, holder: h} <- edges(org, Stake, t), do: h
      end

    Map.new(Enum.uniq(eligible), &{&1, weight(org, e, w, &1, t)})
  end

  def members(org, id, t), do: members(org, get(org, id), t)

  defp weight(_, _, :per_capita, _, _), do: 1

  defp weight(org, e, {:units, class}, p, t),
    do:
      Enum.sum(
        for %Stake{in: ^e, class: ^class, holder: ^p, units: u} <- edges(org, Stake, t), do: u
      )
end
