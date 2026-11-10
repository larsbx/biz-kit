defmodule OrderCore.TransportTest do
  @moduledoc """
  The delivery-owned edges, `last → dispatched → completed | failed`, are taken
  only through `OrderCore.Transport` and only under a transport context; the
  order actions keep refusing them (`:delivery_owned`) to every actor, and the
  two kinds of context are disjoint in both directions.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias OrderCore.{Lifecycle, Transport}

  @wf Lifecycle.workflow!(%{
        fulfillments: [:delivery, :pickup, :dine_in],
        stages: [start_preparing: :preparing, mark_ready: :ready],
        stage_roles: [:admin, :staff]
      })
  @states Lifecycle.states(@wf)
  @owned [{:ready, :dispatched}, {:dispatched, :completed}, {:dispatched, :failed}]

  defp ctx(principal \\ "dispatch-1"),
    do: %{transport: true, principal: principal, merchant: "m", order_id: "o"}

  defp order(state, fulfillment \\ :delivery, version \\ 3),
    do: %{
      merchant: "m",
      id: "o",
      fulfillment: fulfillment,
      state: state,
      version: version,
      seen: %{}
    }

  defp cmd(to, version \\ 3, id \\ "s1"),
    do: %{id: id, expected_version: version, to: to, reason: "lost"}

  defp device(actor, allowed),
    do: %{
      merchant: "m",
      order_id: "o",
      principal: "pos",
      actor: actor,
      granted: true,
      allowed_actions: allowed
    }

  test "authorization precedes any inspection of the order" do
    for bad <- [
          nil,
          %{},
          Map.delete(ctx(), :transport),
          %{ctx() | transport: "yes"},
          %{ctx() | principal: ""},
          Map.put(ctx(), :actor, :system),
          Map.put(ctx(), :granted, true),
          Map.put(ctx(), :allowed_actions, [:dispatch]),
          device(:admin, Map.keys(@wf.actions))
        ],
        garbage <- [nil, :garbage, %{merchant: "m", id: "o"}, order(:ready)] do
      assert Transport.apply(@wf, garbage, bad, cmd(:dispatched)) == {:error, :forbidden}
    end

    for scope <- [%{ctx() | merchant: "other"}, %{ctx() | order_id: "other"}],
        do:
          assert(
            Transport.apply(@wf, order(:ready), scope, cmd(:dispatched)) == {:error, :forbidden}
          )
  end

  test "exactly the three delivery-owned edges, and only for delivery" do
    for f <- @wf.fulfillments, from <- @states, to <- @states do
      result = Transport.apply(@wf, order(from, f), ctx(), cmd(to))

      expected =
        cond do
          f != :delivery -> {:error, :not_a_delivery_order}
          to not in [:dispatched, :completed, :failed] -> {:error, :not_delivery_owned}
          {from, to} not in @owned -> {:error, :invalid_transition}
          true -> :ok
        end

      case expected do
        :ok ->
          assert {:ok, %{state: ^to, version: 4} = next, :accepted} = result
          assert next.seen == %{{:transport, "s1"} => {"dispatch-1", cmd(to)}}

        error ->
          assert result == error, inspect({f, from, to})
      end
    end
  end

  test "commands are typed, versioned, idempotent and a failure carries a reason" do
    ready = order(:ready)

    for bad <- [
          %{},
          %{cmd(:dispatched) | id: ""},
          %{cmd(:dispatched) | id: String.duplicate("x", 129)},
          %{cmd(:dispatched) | expected_version: "3"},
          %{cmd(:dispatched) | to: "dispatched"},
          %{cmd(:dispatched) | reason: 7},
          Map.put(cmd(:dispatched), :action, :dispatch)
        ],
        do: assert(Transport.apply(@wf, ready, ctx(), bad) == {:error, :invalid_order_command})

    assert Transport.apply(@wf, ready, ctx(), cmd(:dispatched, 2)) ==
             {:error, :stale_order_version}

    {:ok, dispatched, :accepted} = Transport.apply(@wf, ready, ctx(), cmd(:dispatched))

    assert Transport.apply(@wf, dispatched, ctx(), cmd(:dispatched)) ==
             {:ok, dispatched, :duplicate}

    for other <- [ctx("dispatch-2")],
        do:
          assert(
            Transport.apply(@wf, dispatched, other, cmd(:dispatched)) ==
              {:error, :idempotency_conflict}
          )

    assert Transport.apply(@wf, dispatched, ctx(), cmd(:completed, 4)) ==
             {:error, :idempotency_conflict}

    for reason <- [nil, ""],
        do:
          assert(
            Transport.apply(@wf, dispatched, ctx(), %{cmd(:failed, 4, "s2") | reason: reason}) ==
              {:error, :reason_required}
          )

    assert {:ok, %{state: :completed}, :accepted} =
             Transport.apply(@wf, dispatched, ctx(), %{cmd(:completed, 4, "s2") | reason: nil})
  end

  test "a transport id never collides with an order command id" do
    {:ok, accepted, :accepted} =
      Lifecycle.apply(@wf, order(:placed, :delivery, 0), device(:admin, [:accept]), %{
        id: "s1",
        expected_version: 0,
        action: :accept
      })

    ready = %{accepted | state: :ready}

    assert {:ok, %{state: :dispatched}, :accepted} =
             Transport.apply(@wf, ready, ctx(), cmd(:dispatched, 1))
  end

  property "the two contexts are disjoint, and the order actions still refuse delivery-owned edges" do
    check all(
            from <- member_of(@states),
            action <- member_of(Map.keys(@wf.actions)),
            actor <- member_of([:admin, :staff, :system]),
            extra <- member_of([:actor, :granted, :allowed_actions, :role])
          ) do
      cmd = %{id: "c", expected_version: 3, action: action, reason: "r"}
      assert Lifecycle.apply(@wf, order(from), ctx(), cmd) == {:error, :forbidden}

      assert Transport.apply(@wf, order(from), Map.put(ctx(), extra, actor), cmd(:dispatched)) ==
               {:error, :forbidden}

      everything = device(actor, Map.keys(@wf.actions))

      case Lifecycle.apply(@wf, order(from), everything, cmd) do
        {:ok, %{state: to}, :accepted} -> refute to in [:dispatched, :completed, :failed]
        {:error, _} -> :ok
      end
    end
  end

  property "histories mixing order actions and transport replay as lifecycle histories, and keep every binding" do
    admin = device(:admin, Map.keys(@wf.actions))
    {:ok, placed} = Lifecycle.new(@wf, "m", "o", :delivery)

    # The kitchen's own path to ready, so transport steps apply.
    {ready, prefix} =
      Enum.reduce([:accept, :start_preparing, :mark_ready], {placed, []}, fn action, {o, h} ->
        cmd = %{id: "k#{o.version}", expected_version: o.version, action: action}
        {:ok, next, :accepted} = Lifecycle.apply(@wf, o, admin, cmd)
        {next, h ++ [{o.state, next.state}]}
      end)

    check all(
            moves <-
              list_of(
                frequency([
                  {1, member_of([:cancel, :mark_ready, :complete])},
                  {3, member_of([:dispatched, :completed, :failed])}
                ]),
                max_length: 6
              )
          ) do
      {final, history} =
        moves
        |> Enum.with_index()
        |> Enum.reduce({ready, prefix}, fn {move, i}, {o, history} ->
          result =
            if move in [:dispatched, :completed, :failed],
              do: Transport.apply(@wf, o, ctx(), %{cmd(move, o.version, "s#{i}") | reason: "r"}),
              else:
                Lifecycle.apply(@wf, o, admin, %{
                  id: "c#{i}",
                  expected_version: o.version,
                  action: move,
                  reason: "r"
                })

          case result do
            {:ok, next, :accepted} ->
              assert Map.take(next.seen, Map.keys(o.seen)) == o.seen
              assert map_size(next.seen) == map_size(o.seen) + 1
              {next, history ++ [{o.state, next.state}]}

            {:error, _} ->
              {o, history}
          end
        end)

      assert Lifecycle.replay(@wf, :delivery, history) == {:ok, final.state}
      assert final.version == length(history)
    end
  end

  test "a retried order command after pickup is still recognised as a duplicate" do
    admin = device(:admin, Map.keys(@wf.actions))
    {:ok, o} = Lifecycle.new(@wf, "m", "o", :delivery)

    {o, cmds} =
      Enum.reduce([:accept, :start_preparing, :mark_ready], {o, []}, fn action, {o, cmds} ->
        cmd = %{id: "k#{o.version}", expected_version: o.version, action: action}
        {:ok, next, :accepted} = Lifecycle.apply(@wf, o, admin, cmd)
        {next, cmds ++ [cmd]}
      end)

    {:ok, dispatched, :accepted} = Transport.apply(@wf, o, ctx(), cmd(:dispatched, 3))
    retried = List.last(cmds)
    assert Lifecycle.apply(@wf, dispatched, admin, retried) == {:ok, dispatched, :duplicate}
  end
end
