defmodule Keel.Invariants do
  @moduledoc """
  Well-formedness of an `Org`, as a declarative list of named, pure checks.

  Static checks see the whole org; temporal checks run at every epoch (see
  `Keel.Org.epochs/1`). A violation is `{name, t | nil, detail}`; repeats of the
  same `{name, detail}` across epochs are reported once, at the earliest `t`.
  """
  alias Keel.{Body, Capability, Graph, Interval, Line, Org, Party, Role, Seat, Stake, Unit}

  @static [:references, :kinds, :intervals, :stakes, :unit_forest]
  @temporal [
    :reports_acyclic,
    :delegation_acyclic,
    :attenuation,
    :seat_limits,
    :agent_accountability
  ]

  def names, do: @static ++ @temporal

  def check(%Org{} = org) do
    static = for n <- @static, d <- apply(__MODULE__, n, [org]), do: {n, nil, d}

    temporal =
      for t <- Org.epochs(org), n <- @temporal, d <- apply(__MODULE__, n, [org, t]), do: {n, t, d}

    Enum.uniq_by(static ++ temporal, fn {n, _, d} -> {n, d} end)
  end

  def valid?(org), do: check(org) == []

  ## Static

  def references(org) do
    for x <- Map.values(org.nodes) ++ org.edges,
        {at, id, sort} <- refs(x),
        not sort?(Org.get(org, id), sort),
        do: {:dangling, at, id, sort}
  end

  defp refs(%Party{}), do: []

  defp refs(%Unit{id: i, of: e, parent: p}),
    do: [{i, e, :entity}] ++ if(p, do: [{i, p, Unit}], else: [])

  defp refs(%Role{id: i, unit: u}), do: [{i, u, Unit}]

  defp refs(%Body{id: i, of: e, members: {:seats, rs}}),
    do: [{i, e, :entity} | for(r <- rs, do: {i, r, Role})]

  defp refs(%Body{id: i, of: e}), do: [{i, e, :entity}]
  defp refs(%Seat{party: p, role: r} = s), do: [{s, p, Party}, {s, r, Role}]
  defp refs(%Line{kind: :reports, from: f, to: t} = l), do: [{l, f, Role}, {l, t, [Role, Body]}]
  defp refs(%Line{from: f, to: t} = l), do: [{l, f, Role}, {l, t, Role}]
  defp refs(%Stake{holder: h, in: e} = s), do: [{s, h, Party}, {s, e, :entity}]

  defp sort?(node, sorts) when is_list(sorts), do: Enum.any?(sorts, &sort?(node, &1))
  defp sort?(node, :entity), do: match?(%Party{kind: :entity}, node)
  defp sort?(node, mod), do: match?(%{__struct__: ^mod}, node)

  def kinds(org) do
    for(
      %Party{kind: k} = p <- Org.nodes(org, Party),
      k not in Party.kinds(),
      do: {:party_kind, p}
    ) ++
      for(%Line{kind: k} = l <- Org.edges(org, Line), k not in Line.kinds(), do: {:line_kind, l}) ++
      for %Body{members: m, weight: w} = b <- Org.nodes(org, Body),
          not (Body.weight?(w) and match?({s, _} when s in [:seats, :stake], m)),
          do: {:body_shape, b}
  end

  def intervals(org),
    do: for(e <- org.edges, not Interval.well_formed?(e.during), do: {:empty, e})

  def stakes(org),
    do:
      for(
        %Stake{units: u} = s <- Org.edges(org, Stake),
        not (is_integer(u) and u > 0),
        do: {:units, s}
      )

  def unit_forest(org) do
    units = Org.nodes(org, Unit)
    parents = for %Unit{id: i, parent: p} <- units, p != nil, do: {i, p}

    cross =
      for %Unit{id: i, of: e, parent: p} <- units,
          %Unit{of: pe} <- [Org.get(org, p)],
          pe != e,
          do: {:cross_entity, i, p}

    cycles(parents) ++ cross
  end

  ## Temporal

  def reports_acyclic(org, t), do: cycles(Org.graph(org, :reports, t))
  def delegation_acyclic(org, t), do: cycles(Org.graph(org, :delegates, t))

  @doc """
  Every delegated grant is covered by the grantor's effective capabilities.
  Sound only jointly with `delegation_acyclic` — a cycle can launder authority.
  """
  def attenuation(org, t) do
    for %Line{kind: :delegates, from: f, to: to, grants: gs} <- Org.edges(org, Line, t),
        match?(%Role{}, Org.get(org, f)),
        have <- [Org.effective(org, f, t)],
        g <- gs,
        not Capability.covered?(have, g),
        do: {:exceeds, f, to, g}
  end

  def seat_limits(org, t) do
    for %Role{id: r, seats: n} <- Org.nodes(org, Role),
        is_integer(n),
        k <- [length(Org.holders(org, r, t))],
        k > n,
        do: {:oversubscribed, r, k, n}
  end

  @doc "Every role an agent holds answers, via `:reports`, to a role or body containing a non-agent."
  def agent_accountability(org, t) do
    reports = Org.graph(org, :reports, t)

    for %Seat{party: p, role: r} <- Org.edges(org, Seat, t),
        match?(%Party{kind: :agent}, Org.get(org, p)),
        not Graph.reaches?(reports, r, &answerable?(org, &1, t)),
        uniq: true,
        do: {:unaccountable, p, r}
  end

  defp answerable?(org, id, t) do
    parties =
      case Org.get(org, id) do
        %Body{} = b -> Map.keys(Org.members(org, b, t))
        %Role{} -> Org.holders(org, id, t)
        _ -> []
      end

    Enum.any?(parties, &match?(%Party{kind: k} when k != :agent, Org.get(org, &1)))
  end

  defp cycles(edges) do
    case Graph.cycle(edges) do
      nil -> []
      c -> [{:cycle, c}]
    end
  end
end
