defmodule AgentOpsStore.EventCursorTest do
  use ExUnit.Case, async: false

  alias AgentOpsStore.EventCursor

  @moduletag :integration

  setup do
    id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    conn = start_supervised!({Postgrex, AgentOpsStore.TestConnection.options()})
    other =
      start_supervised!(
        Supervisor.child_spec({Postgrex, AgentOpsStore.TestConnection.options()}, id: :second_cursor_connection)
      )

    %{conn: conn, other: other, home: "home-" <> id, consumer: "consumer-" <> id}
  end

  defp accepted(ctx, seq, effects \\ []) do
    %{
      home_id: ctx.home,
      consumer_id: ctx.consumer,
      global_seq: seq,
      event_id: "event-#{seq}",
      event_digest: {:bytes, :crypto.hash(:sha256, "committed-event:#{seq}")},
      effects: effects
    }
  end

  defp effect(id, kind \\ "candidate"), do: %{effect_id: id, kind: kind}

  test "complete multi-effect registration, duplicate replay and explicit no-op receipt", ctx do
    one = accepted(ctx, 1, [effect("a-1"), effect("b-1")])
    assert {:ok, %{cursor: 0}} = EventCursor.watermark(ctx.conn, ctx.home, ctx.consumer)

    assert {:ok, %{cursor: 1, disposition: :new}} = EventCursor.commit(ctx.conn, one)
    assert {:ok, %{cursor: 1, disposition: :existing}} = EventCursor.commit(ctx.conn, one)

    assert {:ok, %{cursor: 1}} = EventCursor.watermark(ctx.conn, ctx.home, ctx.consumer)

    assert {:ok, %{cursor: 2, disposition: :new}} =
             EventCursor.commit(ctx.conn, accepted(ctx, 2, []))

    {:ok, %Postgrex.Result{rows: [[count]]}} =
      Postgrex.query(ctx.conn, """
      SELECT count(*) FROM agent_ops.consumer_effects
      WHERE home_id=$1 AND consumer_id=$2
      """, [ctx.home, ctx.consumer])

    assert count == 2

    {:ok, %Postgrex.Result{rows: [[receipt]]}} =
      Postgrex.query(ctx.conn, """
      SELECT effect_bundle FROM agent_ops.consumer_processed
      WHERE home_id=$1 AND consumer_id=$2 AND global_seq=2
      """, [ctx.home, ctx.consumer])

    assert receipt == []
  end

  test "cursor never advances across gaps, changed replay or partial bundle", ctx do
    assert {:error, :event_cursor_transaction_refused} =
             EventCursor.commit(ctx.conn, accepted(ctx, 2))

    one = accepted(ctx, 1, [effect("existing-effect")])
    assert {:ok, %{disposition: :new}} = EventCursor.commit(ctx.conn, one)

    assert {:error, :event_cursor_transaction_refused} =
             EventCursor.commit(ctx.conn, accepted(ctx, 1, []))

    # event 2 tries to reuse a different event's immutable effect ID. Its
    # processed receipt was inserted first but must roll back with the failed
    # insert; no partial acknowledgement is permitted.
    assert {:error, :event_cursor_transaction_refused} =
             EventCursor.commit(ctx.conn, accepted(ctx, 2, [effect("existing-effect")]))

    assert {:ok, 1} = EventCursor.watermark(ctx.conn, ctx.home, ctx.consumer)

    {:ok, %Postgrex.Result{rows: [[count]]}} =
      Postgrex.query(ctx.conn, """
      SELECT count(*) FROM agent_ops.consumer_processed
      WHERE home_id=$1 AND consumer_id=$2
      """, [ctx.home, ctx.consumer])
    assert count == 1

    assert {:ok, %{cursor: 2, disposition: :new}} =
             EventCursor.commit(ctx.conn, accepted(ctx, 2, [effect("new-effect")]))
  end

  test "two independent PostgreSQL connections race with one winning transaction", ctx do
    one = accepted(ctx, 1, [effect("competing-effect")])

    a = Task.async(fn -> EventCursor.commit(ctx.conn, one) end)
    b = Task.async(fn -> EventCursor.commit(ctx.other, one) end)
    results = [Task.await(a, 15_000), Task.await(b, 15_000)]

    assert Enum.count(results, &match?({:ok, %{disposition: :new}}, &1)) == 1
    assert Enum.count(results, &match?({:ok, %{disposition: :existing}}, &1)) == 1
    assert {:ok, 1} = EventCursor.watermark(ctx.other, ctx.home, ctx.consumer)

    {:ok, %Postgrex.Result{rows: [[count]]}} =
      Postgrex.query(ctx.conn, """
      SELECT count(*) FROM agent_ops.consumer_effects
      WHERE home_id=$1 AND consumer_id=$2
      """, [ctx.home, ctx.consumer])
    assert count == 1
  end

  test "untrusted shapes and scope collisions fail closed", ctx do
    invalid = [
      %{accepted(ctx, 1) | global_seq: 0},
      %{accepted(ctx, 1) | home_id: "../wrong"},
      %{accepted(ctx, 1) | event_digest: "wrong"},
      accepted(ctx, 1, [effect("dup"), effect("dup")]),
      accepted(ctx, 1, [effect("../escape")])
    ]

    for event <- invalid do
      assert {:error, :invalid_event_bundle} = EventCursor.commit(ctx.conn, event)
    end

    assert {:ok, 0} = EventCursor.watermark(ctx.conn, ctx.home, ctx.consumer)

    assert {:ok, %{cursor: 1, disposition: :new}} =
             EventCursor.commit(ctx.conn, accepted(ctx, 1))
    assert {:ok, %{cursor: 1, disposition: :new}} =
             EventCursor.commit(ctx.conn, %{accepted(ctx, 1) | home_id: ctx.home <> "-other"})

    assert {:ok, 1} = EventCursor.watermark(ctx.conn, ctx.home, ctx.consumer)
    assert {:ok, 1} = EventCursor.watermark(ctx.conn, ctx.home <> "-other", ctx.consumer)
  end
end
