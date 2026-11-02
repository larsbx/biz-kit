defmodule CommerceCore.OrderLifecycleTest do
  @moduledoc """
  The merchant-neutral lifecycle over arbitrary production stages `s₁ … sₙ`
  (n ∈ 0..4). The kitchen instance is pinned against the legacy fixtures in
  RestaurantCore; these properties hold for every workflow.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CommerceCore.OrderLifecycle, as: Core

  @fulfillments [:delivery, :pickup, :ship]
  @all_actions ~w(accept dispatch complete fail cancel)a

  defp definition(ids, fulfillments \\ @fulfillments) do
    %{
      fulfillments: fulfillments,
      stages: for(i <- ids, do: {:"stage_action_#{i}", :"stage_#{i}"}),
      stage_roles: [:admin, :staff]
    }
  end

  defp stages, do: uniq_list_of(integer(0..9), max_length: 4)

  defp trusted(actor, allowed),
    do: %{
      merchant: "m",
      order_id: "o",
      principal: "p",
      actor: actor,
      granted: true,
      allowed_actions: allowed
    }

  defp cmd(action, n), do: %{id: "c#{n}", expected_version: n, action: action, reason: "r"}

  # Applies `actions` as an all-powerful admin, collecting the result of each step.
  defp run(workflow, fulfillment, actions) do
    {:ok, order} = Core.new(workflow, "m", "o", fulfillment)
    admin = trusted(:admin, Map.keys(workflow.actions))

    Enum.reduce_while(actions, {:ok, order}, fn action, {:ok, o} ->
      case Core.apply(workflow, o, admin, cmd(action, o.version)) do
        {:ok, o, :accepted} -> {:cont, {:ok, o}}
        error -> {:halt, {error, o}}
      end
    end)
  end

  property "δ: the stages sit between acceptance and hand-off, terminals absorb" do
    check all(ids <- stages()) do
      {:ok, w} = Core.workflow(definition(ids))
      names = Enum.map(ids, &:"stage_#{&1}")
      sequence = [:accepted | names]
      last = List.last(sequence)

      assert Core.states(w) ==
               [:placed | sequence] ++ ~w(dispatched completed cancelled failed)a

      for f <- @fulfillments do
        assert Core.next_states(w, f, :placed) == [:accepted, :cancelled]

        for {from, to} <- Enum.zip(sequence, tl(sequence)),
            do: assert(Core.next_states(w, f, from) == [to, :cancelled])

        hand_off = if f == :delivery, do: :dispatched, else: :completed
        assert Core.next_states(w, f, last) == [hand_off, :cancelled]

        assert Core.next_states(w, f, :dispatched) ==
                 if(f == :delivery, do: [:completed, :failed], else: [])

        for t <- Core.terminal_states(), do: assert(Core.next_states(w, f, t) == [])
      end

      assert Core.next_states(w, :unknown, :placed) == []
    end
  end

  property "the stage actions walk a non-delivery order to completion; replay agrees" do
    check all(ids <- stages(), f <- member_of([:pickup, :ship])) do
      {:ok, w} = Core.workflow(definition(ids))
      stage_actions = Enum.map(ids, &:"stage_action_#{&1}")

      assert {:ok, order} = run(w, f, [:accept | stage_actions] ++ [:complete])
      assert order.state == :completed
      assert order.version == length(ids) + 2

      path = [:placed, :accepted | Enum.map(ids, &:"stage_#{&1}")] ++ [:completed]
      assert Core.replay(w, f, Enum.zip(path, tl(path))) == {:ok, :completed}
    end
  end

  property "delivery hand-off is never an order action, even for an admin" do
    check all(ids <- stages(), action <- member_of([:dispatch, :complete])) do
      {:ok, w} = Core.workflow(definition(ids))
      stage_actions = Enum.map(ids, &:"stage_action_#{&1}")

      assert {{:error, expected}, order} =
               run(w, :delivery, [:accept | stage_actions] ++ [action])

      assert order.state == List.last([:accepted | Enum.map(ids, &:"stage_#{&1}")])
      assert expected == if(action == :dispatch, do: :delivery_owned, else: :invalid_transition)
    end
  end

  property "authorization precedes every observation of state" do
    check all(
            ids <- stages(),
            actor <- member_of([:admin, :staff, :system, :public]),
            action <- member_of(@all_actions ++ [:stage_action_0, :unknown]),
            allowed <- list_of(member_of(@all_actions ++ [:stage_action_0])),
            garbage <- term()
          ) do
      {:ok, w} = Core.workflow(definition(ids))
      ctx = trusted(actor, allowed)

      unless Core.authorized?(w, ctx, action) do
        assert Core.apply(w, garbage, ctx, cmd(action, 0)) == {:error, :forbidden}
      end

      case Map.get(w.actions, action) do
        {_, roles} ->
          assert Core.authorized?(w, ctx, action) == (actor in roles and action in allowed)

        nil ->
          refute Core.authorized?(w, ctx, action)
      end
    end
  end

  property "stage actions are taken by exactly the stage roles" do
    check all(ids <- stages(), actor <- member_of([:admin, :staff, :system])) do
      w = Core.workflow!(definition(ids))
      ctx = trusted(actor, Map.keys(w.actions))

      for i <- ids,
          do: assert(Core.authorized?(w, ctx, :"stage_action_#{i}") == (actor != :system))
    end
  end

  property "replay refuses any history that leaves δ or breaks continuity" do
    check all(
            ids <- stages(),
            f <- member_of(@fulfillments),
            from <- integer(0..8),
            to <- integer(0..8)
          ) do
      w = Core.workflow!(definition(ids))
      states = Core.states(w)

      {a, b} =
        {Enum.at(states, rem(from, length(states))), Enum.at(states, rem(to, length(states)))}

      start = [{:placed, :accepted}]

      expected =
        cond do
          a != :accepted -> {:error, {:discontinuous, 1}}
          Core.legal?(w, f, a, b) -> {:ok, b}
          true -> {:error, {:illegal, 1, a, b}}
        end

      assert Core.replay(w, f, start ++ [{a, b}]) == expected
    end
  end

  test "authorized commands still meet scope, revision, reason and idempotency" do
    w = Core.workflow!(definition([0]))
    admin = trusted(:admin, Map.keys(w.actions))
    {:ok, order} = Core.new(w, "m", "o", :pickup)

    assert Core.apply(w, order, %{admin | merchant: "x"}, cmd(:accept, 0)) == {:error, :forbidden}
    assert Core.apply(w, order, %{admin | order_id: "x"}, cmd(:accept, 0)) == {:error, :forbidden}
    assert Core.apply(w, order, admin, cmd(:accept, 1)) == {:error, :stale_order_version}

    assert Core.apply(w, order, admin, %{cmd(:cancel, 0) | reason: ""}) ==
             {:error, :reason_required}

    assert Core.apply(w, order, admin, Map.delete(cmd(:cancel, 0), :reason)) ==
             {:error, :reason_required}

    assert Core.apply(w, order, admin, %{action: :accept}) == {:error, :invalid_order_command}

    {:ok, accepted, :accepted} = Core.apply(w, order, admin, cmd(:accept, 0))
    assert {:ok, ^accepted, :duplicate} = Core.apply(w, accepted, admin, cmd(:accept, 0))

    assert Core.apply(w, accepted, admin, %{cmd(:cancel, 0) | id: "c0"}) ==
             {:error, :idempotency_conflict}
  end

  test "a retail workflow: picking and packing, then hand-off" do
    w =
      Core.workflow!(%{
        fulfillments: [:pickup, :delivery],
        stages: [pick: :picking, pack: :packed],
        stage_roles: [:admin, :staff]
      })

    assert {:ok, %{state: :completed}} = run(w, :pickup, [:accept, :pick, :pack, :complete])

    assert {{:error, :delivery_owned}, %{state: :packed}} =
             run(w, :delivery, ~w(accept pick pack dispatch)a)

    assert {{:error, :forbidden}, _} = run(w, :pickup, [:accept, :start_preparing])
    assert Core.new(w, "m", "o", :dine_in) == {:error, :invalid_order}
  end

  test "no stages: acceptance is the hand-off point" do
    w = Core.workflow!(definition([]))
    assert Core.next_states(w, :pickup, :accepted) == [:completed, :cancelled]
    assert Core.next_states(w, :delivery, :accepted) == [:dispatched, :cancelled]
    assert {:ok, %{state: :completed, version: 2}} = run(w, :pickup, [:accept, :complete])
  end

  test "malformed workflows are refused" do
    base = %{fulfillments: [:pickup], stages: [pick: :picking], stage_roles: [:staff]}

    for bad <- [
          %{base | fulfillments: []},
          %{base | fulfillments: [:pickup, :pickup]},
          %{base | fulfillments: ["pickup"]},
          %{base | stage_roles: []},
          %{base | stages: [pick: :picking, pack: :picking]},
          %{base | stages: [pick: :picking, pick: :packed]},
          %{base | stages: [pick: :completed]},
          %{base | stages: [accept: :picking]},
          %{base | stages: [:picking]},
          %{base | stages: [{"pick", :picking}]},
          Map.delete(base, :stages),
          nil
        ] do
      assert Core.workflow(bad) == {:error, :invalid_workflow}
    end

    assert_raise ArgumentError, fn -> Core.workflow!(%{base | stages: [pick: :placed]}) end
  end
end
