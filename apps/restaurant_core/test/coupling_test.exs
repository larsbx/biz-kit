defmodule RestaurantCore.CouplingTest do
  @moduledoc """
  The I8 relation as data, checked against itself and against the pinned
  reducers it composes: Kitchen (OrderCore.Lifecycle), OrderCore.Transport and
  FulfillmentCore. Every pair, every step.
  """
  use ExUnit.Case, async: true

  alias FulfillmentCore.OrderCoupling
  alias OrderCore.Transport
  alias RestaurantCore.{Coupling, Kitchen}

  @views ~w(none requested accepted in_transit withdrawn cancel_pending cancel_in_transit
            rejected cancelled cancelled_in_transit delivered failed_before_pickup failed_in_transit)a
  @owned ~w(dispatched completed failed)a

  @delivery [
    placed: :none,
    accepted: :none,
    preparing: :none,
    ready: :none,
    cancelled: :none,
    ready: :requested,
    ready: :accepted,
    ready: :withdrawn,
    ready: :cancel_pending,
    ready: :rejected,
    ready: :cancelled,
    ready: :failed_before_pickup,
    dispatched: :in_transit,
    completed: :delivered,
    failed: :failed_in_transit,
    cancelled: :withdrawn,
    cancelled: :rejected,
    cancelled: :cancelled,
    cancelled: :failed_before_pickup
  ]

  @rows [
    {{:placed, :none}, :restaurant, {:kitchen, :accept}, {:accepted, :none}, :kitchen},
    {{:accepted, :none}, :restaurant, {:kitchen, :start_preparing}, {:preparing, :none},
     :kitchen},
    {{:preparing, :none}, :restaurant, {:kitchen, :mark_ready}, {:ready, :none}, :kitchen},
    {{:placed, :none}, :restaurant, {:kitchen, :cancel}, {:cancelled, :none}, :kitchen},
    {{:accepted, :none}, :restaurant, {:kitchen, :cancel}, {:cancelled, :none}, :kitchen},
    {{:preparing, :none}, :restaurant, {:kitchen, :cancel}, {:cancelled, :none}, :kitchen},
    {{:ready, :none}, :restaurant, {:kitchen, :cancel}, {:cancelled, :none}, :kitchen},
    {{:ready, :withdrawn}, :restaurant, {:kitchen, :cancel}, {:cancelled, :withdrawn}, :kitchen},
    {{:ready, :rejected}, :restaurant, {:kitchen, :cancel}, {:cancelled, :rejected}, :kitchen},
    {{:ready, :cancelled}, :restaurant, {:kitchen, :cancel}, {:cancelled, :cancelled}, :kitchen},
    {{:ready, :failed_before_pickup}, :restaurant, {:kitchen, :cancel},
     {:cancelled, :failed_before_pickup}, :kitchen},
    {{:ready, :none}, :restaurant, :request, {:ready, :requested}, :hold},
    {{:ready, :rejected}, :restaurant, :request, {:ready, :requested}, :hold},
    {{:ready, :cancelled}, :restaurant, :request, {:ready, :requested}, :hold},
    {{:ready, :failed_before_pickup}, :restaurant, :request, {:ready, :requested}, :hold},
    {{:ready, :requested}, :restaurant, :withdraw, {:ready, :withdrawn}, :hold},
    {{:ready, :accepted}, :restaurant, :withdraw, {:ready, :cancel_pending}, :hold},
    {{:ready, :requested}, :dispatch, {:dispatch, :accept}, {:ready, :accepted}, :hold},
    {{:ready, :withdrawn}, :dispatch, {:dispatch, :accept}, {:ready, :cancel_pending}, :hold},
    {{:ready, :requested}, :dispatch, {:dispatch, :reject}, {:ready, :rejected}, :hold},
    {{:ready, :withdrawn}, :dispatch, {:dispatch, :reject}, {:ready, :rejected}, :hold},
    {{:cancelled, :withdrawn}, :dispatch, {:dispatch, :reject}, {:cancelled, :rejected}, :hold},
    {{:ready, :withdrawn}, :dispatch, {:dispatch, :cancel_confirmed}, {:ready, :cancelled},
     :hold},
    {{:ready, :cancel_pending}, :dispatch, {:dispatch, :cancel_confirmed}, {:ready, :cancelled},
     :hold},
    {{:cancelled, :withdrawn}, :dispatch, {:dispatch, :cancel_confirmed},
     {:cancelled, :cancelled}, :hold},
    {{:ready, :accepted}, :dispatch, {:dispatch, :in_transit}, {:dispatched, :in_transit},
     :transport},
    {{:dispatched, :in_transit}, :dispatch, {:dispatch, :delivered}, {:completed, :delivered},
     :transport},
    {{:ready, :accepted}, :dispatch, {:dispatch, :failed}, {:ready, :failed_before_pickup},
     :hold},
    {{:ready, :cancel_pending}, :dispatch, {:dispatch, :failed}, {:ready, :failed_before_pickup},
     :hold},
    {{:dispatched, :in_transit}, :dispatch, {:dispatch, :failed}, {:failed, :failed_in_transit},
     :transport}
  ]

  @strict %{
    {{:ready, :requested}, {:kitchen, :cancel}} => :transport_pending,
    {{:ready, :accepted}, {:kitchen, :cancel}} => :transport_pending,
    {{:ready, :cancel_pending}, {:kitchen, :cancel}} => :transport_pending,
    {{:dispatched, :in_transit}, :withdraw} => :transport_started,
    {{:ready, :cancel_pending}, {:dispatch, :in_transit}} => :cancel_pending,
    {{:cancelled, :withdrawn}, {:dispatch, :accept}} => :order_cancelled
  }

  @dispatch_ops ~w(accept reject in_transit delivered failed cancel_confirmed)a
  @kitchen_actions Map.keys(Kitchen.workflow().actions)

  defp ops,
    do:
      Enum.map(@kitchen_actions, &{:kitchen, &1}) ++
        [:request, :withdraw] ++ Enum.map(@dispatch_ops, &{:dispatch, &1})

  test "states, views and the coupled pairs over all 312 triples" do
    assert Coupling.states() == Kitchen.states()
    assert Coupling.views() == @views
    assert Coupling.live() == [:requested, :accepted, :cancel_pending]
    assert Coupling.requestable() == [:none, :rejected, :cancelled, :failed_before_pickup]

    simple = for s <- ~w(placed accepted preparing ready completed cancelled)a, do: {s, :none}

    for f <- Kitchen.workflow().fulfillments, s <- Coupling.states(), v <- @views do
      expected = {s, v} in if(f == :delivery, do: @delivery, else: simple)
      assert Coupling.coupled?(f, s, v) == expected, inspect({f, s, v})
    end

    assert length(@delivery) == 19 and length(Enum.uniq(@delivery)) == 19
  end

  test "the rows are exactly the 30 joint steps, keyed by source pair and op" do
    assert Coupling.rows() == @rows
    assert @rows |> Enum.map(&{elem(&1, 0), elem(&1, 2)}) |> Enum.uniq() |> length() == 30

    for {from, _, op, _, _} = row <- @rows, do: assert(Coupling.row(from, op) == {:ok, row})
    assert Coupling.row({:ready, :none}, {:dispatch, :accept}) == :error
    assert Coupling.strict() == @strict
    assert Enum.all?(Map.keys(@strict), fn {from, op} -> Coupling.row(from, op) == :error end)
  end

  test "closure: every row joins coupled pairs, and the rows reach exactly the coupled set" do
    for {from, _, _, to, _} <- @rows,
        do: assert(from in @delivery and to in @delivery)

    assert MapSet.new(reach({:placed, :none})) == MapSet.new(@delivery)
  end

  test "provenance: order edges into dispatched, completed or failed are Dispatch transport; every other order edge is the kitchen's" do
    for {{s, v}, owner, op, {t, w}, effect} <- @rows do
      owner_of_op = if match?({:dispatch, _}, op), do: :dispatch, else: :restaurant
      assert owner == owner_of_op

      cond do
        t != s and t in @owned -> assert {owner, effect} == {:dispatch, :transport}
        t != s -> assert {owner, effect} == {:restaurant, :kitchen}
        true -> assert effect == :hold
      end

      if t != s,
        do:
          assert(
            OrderCoupling.order_edge_owner(s, t) ==
              if(effect == :transport, do: :delivery, else: :order)
          )

      if w != v and w in [:requested, :withdrawn],
        do: assert(owner == :restaurant)

      if w != v and w not in [:requested, :withdrawn, :cancel_pending],
        do: assert(owner == :dispatch)
    end
  end

  test "while transport is live the order does not move except by Dispatch's pickup" do
    for {{s, v}, _, op, {t, _}, _} <- @rows,
        v in Coupling.live(),
        t != s,
        do: assert({{s, v}, op} == {{:ready, :accepted}, {:dispatch, :in_transit}})

    for {{:ready, :cancel_pending}, _, _, {t, _}, effect} <- @rows,
        do: assert({t, effect} == {:ready, :hold})
  end

  test "view/1 is total over every FulfillmentCore state both actors can reach" do
    reached = fulfillment_reach()
    views = reached |> Enum.map(&Coupling.view/1) |> MapSet.new()

    assert Coupling.view(nil) == :none
    assert MapSet.size(MapSet.new(reached, &abstract/1)) == 13
    assert views == MapSet.new(@views -- [:none])
  end

  test "agreement: on every coupled pair the reducers accept exactly the rows and the strict cells" do
    reps =
      fulfillment_reach()
      |> Enum.group_by(&Coupling.view/1)
      |> Map.new(fn {v, [fc | _]} -> {v, fc} end)

    for {s, v} = from <- @delivery, op <- ops() do
      order = %{merchant: "m", id: "o", fulfillment: :delivery, state: s, version: 0, seen: %{}}
      fc = if v == :none, do: nil, else: Map.fetch!(reps, v)
      result = reduce(order, fc, op)

      case {Coupling.row(from, op), Map.fetch(@strict, {from, op})} do
        {{:ok, {_, _, _, to, :transport}}, :error} ->
          {:ok, fc2} = result
          target = Coupling.transport_target(elem(op, 1))

          assert {:ok, next, :accepted} =
                   Transport.apply(Kitchen.workflow(), order, transport(), %{
                     id: "s",
                     expected_version: 0,
                     to: target,
                     reason: "r"
                   })

          assert {next.state, Coupling.view(fc2)} == to

        {{:ok, {_, _, _, to, effect}}, :error} ->
          assert {:ok, next} = result, inspect({from, op})
          state = if effect == :kitchen, do: next.state, else: s
          view = if effect == :kitchen, do: v, else: Coupling.view(next)
          assert {state, view} == to, inspect({from, op})

        {:error, {:ok, _}} ->
          assert {:ok, _} = result, inspect({from, op})

        {:error, :error} ->
          assert {:error, _} = result, inspect({from, op, result})
      end
    end
  end

  test "dispatch fields are exact per op, and the transport targets are the delivery-owned states" do
    assert Coupling.dispatch_fields("accept") == {:ok, :accept, ["transport_ref"]}
    assert Coupling.dispatch_fields("reject") == {:ok, :reject, ["reason"]}
    assert Coupling.dispatch_fields("in_transit") == {:ok, :in_transit, []}
    assert Coupling.dispatch_fields("delivered") == {:ok, :delivered, ["proof"]}
    assert Coupling.dispatch_fields("failed") == {:ok, :failed, ["proof", "reason"]}
    assert Coupling.dispatch_fields("cancel_confirmed") == {:ok, :cancel_confirmed, []}
    assert Coupling.dispatch_fields("cancel") == :error

    assert Enum.map(~w(in_transit delivered failed)a, &Coupling.transport_target/1) == @owned
  end

  test "the Quint obligation model states exactly these rows, and its control exactly the strict cells" do
    qnt =
      File.read!(
        Path.expand("../../../formal/quint/obligations/restaurant_delivery.qnt", __DIR__)
      )

    [rows_src, loose_src] = qnt |> String.split("pure val LOOSE") |> Enum.take(2)

    parse = fn src ->
      ~r/r\(\("(\w+)", "(\w+)"\),\s*"(\w+)",\s*"(\w+)",\s*\("(\w+)", "(\w+)"\),\s*(true|false)\)/
      |> Regex.scan(src, capture: :all_but_first)
      |> Enum.map(fn [s, v, by, op, t, w, proof] ->
        {{String.to_atom(s), String.to_atom(v)}, by, op, {String.to_atom(t), String.to_atom(w)},
         proof == "true"}
      end)
    end

    quint = fn {from, owner, op, to, _} ->
      name =
        case op do
          {_, action} -> Atom.to_string(action)
          op -> Atom.to_string(op)
        end

      proof = match?({:dispatch, p} when p in [:delivered, :failed], op)
      {from, Atom.to_string(owner), name, to, proof}
    end

    assert Enum.sort(parse.(rows_src)) == Enum.sort(Enum.map(@rows, quint))

    loose = parse.(loose_src)
    assert length(loose) == map_size(@strict) + 1

    assert MapSet.new(loose, fn {from, by, op, _, _} -> {from, by, op} end) ==
             MapSet.new(
               [{{:dispatched, :in_transit}, "dispatch", "delivered"}] ++
                 for {{from, op}, _} <- @strict do
                   {from, _, name, _, _} = quint.({from, owner(op), op, nil, nil})
                   {from, Atom.to_string(owner(op)), name}
                 end
             )
  end

  defp owner({:dispatch, _}), do: :dispatch
  defp owner(_), do: :restaurant

  defp transport, do: %{transport: true, principal: "d", merchant: "m", order_id: "o"}

  # The pinned reducers alone: Kitchen for an order action under an admin holding
  # every action; FulfillmentCore for the handoff; a request is admissible on the
  # reducers' side when the order is ready and has no live handoff.
  defp reduce(order, _fc, {:kitchen, action}) do
    admin = %{
      merchant: "m",
      order_id: "o",
      principal: "pos",
      actor: :admin,
      granted: true,
      allowed_actions: @kitchen_actions
    }

    case Kitchen.apply(order, admin, %{id: "k", expected_version: 0, action: action, reason: "r"}) do
      {:ok, next, :accepted} -> {:ok, next}
      error -> error
    end
  end

  defp reduce(%{state: :ready}, fc, :request) do
    if fc == nil or not FulfillmentCore.pending?(fc),
      do: FulfillmentCore.new("m", "r2", "o", "restaurant-courier"),
      else: {:error, :pending}
  end

  defp reduce(_, _, :request), do: {:error, :not_ready}
  defp reduce(_, nil, _), do: {:error, :no_handoff}
  defp reduce(_, fc, :withdraw), do: fc_apply(fc, :commerce, :cancel)
  defp reduce(_, fc, {:dispatch, op}), do: fc_apply(fc, :dispatch, op)

  defp fc_apply(fc, actor, op) do
    event = %{
      id: "e#{fc.version}",
      expected_version: fc.version,
      op: op,
      transport_ref: "t",
      reason: "r",
      proof_ref: "p"
    }

    case FulfillmentCore.apply(fc, "m", actor, event) do
      {:ok, next, :accepted} -> {:ok, next}
      error -> error
    end
  end

  defp reach(start) do
    Stream.iterate({[start], [start]}, fn {seen, frontier} ->
      next =
        for {from, _, _, to, _} <- @rows, from in frontier, to not in seen, uniq: true, do: to

      {seen ++ next, next}
    end)
    |> Enum.find(fn {_, frontier} -> frontier == [] end)
    |> elem(0)
  end

  defp abstract(fc), do: {fc.phase, fc.transport_ref != nil, fc.transport_started}

  # Every FulfillmentCore state reachable from a request under both actors and
  # every op, up to the abstraction (phase, has a transport ref, started).
  defp fulfillment_reach do
    {:ok, start} = FulfillmentCore.new("m", "r", "o", "restaurant-courier")

    Stream.iterate({%{abstract(start) => start}, [start]}, fn {seen, frontier} ->
      next =
        for fc <- frontier,
            {actor, op} <- [{:commerce, :cancel} | Enum.map(@dispatch_ops, &{:dispatch, &1})],
            {:ok, n} <- [fc_apply(fc, actor, op)],
            not Map.has_key?(seen, abstract(n)),
            uniq: true,
            do: n

      next = Enum.uniq_by(next, &abstract/1)
      {Map.merge(seen, Map.new(next, &{abstract(&1), &1})), next}
    end)
    |> Enum.find(fn {_, frontier} -> frontier == [] end)
    |> elem(0)
    |> Map.values()
  end
end
