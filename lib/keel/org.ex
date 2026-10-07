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

  @doc "The body of entity `e` with the most specific voice covering `matter`, or `nil`."
  def voice(org, e, matter) do
    pairs =
      for %Body{of: ^e, id: b, voices: vs} <- nodes(org, Body),
          v <- vs,
          Capability.covers?(v, matter),
          do: {b, v}

    case Enum.find(pairs, fn {_, v} ->
           Enum.all?(pairs, fn {_, w} -> Capability.covers?(w, v) end)
         end) do
      {b, _} -> b
      nil -> nil
    end
  end

  def capabilities(org, party, t),
    do: org |> roles(party, t) |> Enum.flat_map(&effective(org, &1, t)) |> Enum.uniq()

  def can?(org, party, need, t), do: Capability.covered?(capabilities(org, party, t), need)

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
