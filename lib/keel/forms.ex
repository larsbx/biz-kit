defmodule Keel.Forms do
  @moduledoc """
  Canonical company forms as plain lists of Keel primitives.

  Forms create structure, not people: callers declare the parties. Ids are
  namespaced by entity (`{e, :hq}`, `{e, dept, :head}`), so forms compose by
  list concatenation — a holding company is two corporations, not a new form.
  """
  alias Keel.{Body, Class, Line, Party, Role, Seat, Stake, Unit}

  @fundamental [:sell, :merge, :dissolve, :amend_charter]

  @doc "Matters reserved to the owners (or members) by default: those that end or remake the company."
  def fundamental, do: @fundamental

  def entity(e), do: [%Party{id: e, kind: :entity}, %Unit{id: {e, :hq}, of: e, kind: :entity}]

  @doc "Stakes of `class` plus the owners' body, weighted by units, reserving `reserves`."
  def owners(e, holdings, class \\ :equity, reserves \\ @fundamental) do
    [
      %Body{
        id: {e, :owners},
        of: e,
        members: {:stake, class},
        weight: {:units, class},
        grants: [:*],
        reserves: reserves
      }
    ] ++
      for {p, units} <- holdings, do: %Stake{holder: p, in: e, class: class, units: units}
  end

  @doc "A single plenary role: seated by `parties`, answering to `superior`."
  def executive(e, role, parties, superior, seats \\ :any) do
    [
      %Role{id: {e, role}, unit: {e, :hq}, grants: [:*], seats: seats},
      %Line{from: {e, role}, to: superior}
    ] ++ for p <- parties, do: %Seat{party: p, role: {e, role}}
  end

  @doc "Nothing is reserved: owner and executive coincide, so a reservation would only add friction."
  def sole_proprietorship(e, owner),
    do:
      entity(e) ++
        owners(e, [{owner, 1}], :equity, []) ++
        executive(e, :principal, [owner], {e, :owners}, 1)

  @doc "Partnership / LLC. `partners :: [{party, units}]`; managers default to all partners."
  def partnership(e, partners, managers \\ nil) do
    managers = managers || Enum.map(partners, &elem(&1, 0))
    entity(e) ++ owners(e, partners) ++ executive(e, :manager, managers, {e, :owners})
  end

  @doc "Shareholders elect a board (per capita), which oversees a CEO."
  def corporation(e, shareholders, directors, ceo) do
    entity(e) ++
      owners(e, shareholders, :common) ++
      [
        %Role{id: {e, :director}, unit: {e, :hq}, grants: [:govern], seats: length(directors)},
        %Line{from: {e, :director}, to: {e, :owners}},
        %Body{id: {e, :board}, of: e, members: {:seats, [{e, :director}]}, grants: [:*]}
      ] ++
      for(d <- directors, do: %Seat{party: d, role: {e, :director}}) ++
      executive(e, :ceo, [ceo], {e, :board}, 1)
  end

  @doc """
  Co-operative: one member, one vote — control by `:membership`, economics by
  `:capital` (`opts[:capital] :: %{party => units}`), never conflated.
  """
  def cooperative(e, members, manager, opts \\ []) do
    entity(e) ++
      [
        %Body{
          id: {e, :assembly},
          of: e,
          members: {:stake, :membership},
          weight: :per_capita,
          grants: [:*],
          reserves: @fundamental
        }
      ] ++
      for(p <- members, do: %Stake{holder: p, in: e, class: :membership}) ++
      for(
        {p, u} <- Keyword.get(opts, :capital, %{}),
        do: %Stake{holder: p, in: e, class: :capital, units: u}
      ) ++
      executive(e, :manager, [manager], {e, :assembly}, 1)
  end

  @doc """
  Worker co-operative: a co-op whose membership class is employees-only. Every
  member is seated as `{e, :worker}`; a stake outliving the seat is a violation.
  """
  def worker_cooperative(e, members, manager, opts \\ []) do
    cooperative(e, members, manager, opts) ++
      [
        %Class{id: {e, :class, :membership}, of: e, name: :membership, eligible: :employees},
        %Role{id: {e, :worker}, unit: {e, :hq}}
      ] ++ for(p <- members, do: %Seat{party: p, role: {e, :worker}})
  end

  @doc """
  Employee trust (ESOP / EOT) for `company`: an entity, run by `trustee`, whose
  `:beneficial` units may be held only by employees of `company`.

  The trust votes its holdings by look-through: beneficiaries voice the
  `reserved` matters, weighted by allocation (`weight: :per_capita` for
  equal-share trusts); the trustee voices every matter (`:*`) and votes the
  holding whenever beneficiaries fail to reach a decision (undirected shares).
  """
  def employee_trust(
        trust,
        company,
        trustee,
        allocations,
        reserved,
        weight \\ {:units, :beneficial}
      ) do
    entity(trust) ++
      [
        %Class{
          id: {trust, :class, :beneficial},
          of: trust,
          name: :beneficial,
          eligible: {:employees, company}
        },
        %Role{id: {trust, :trustee}, unit: {trust, :hq}, grants: [:administer], seats: 1},
        %Seat{party: trustee, role: {trust, :trustee}},
        %Body{
          id: {trust, :trustees},
          of: trust,
          members: {:seats, [{trust, :trustee}]},
          grants: [:*],
          voices: [:*]
        },
        %Body{
          id: {trust, :beneficiaries},
          of: trust,
          members: {:stake, :beneficial},
          weight: weight,
          grants: reserved,
          voices: reserved
        }
      ] ++
      for {p, u} <- allocations, do: %Stake{holder: p, in: trust, class: :beneficial, units: u}
  end

  @doc "A department whose head holds only what `superior` delegates."
  def department(e, d, superior, grants) do
    head = {e, d, :head}

    [
      %Unit{id: {e, d}, of: e, parent: {e, :hq}, kind: :department},
      %Role{id: head, unit: {e, d}, seats: 1},
      %Line{from: head, to: superior},
      %Line{kind: :delegates, from: superior, to: head, grants: grants}
    ]
  end
end
