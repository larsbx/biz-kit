defmodule AgentOpsStore.EventReplayTest do
  use ExUnit.Case, async: false

  alias AgentOpsStore.{EventCursor, EventReplay}

  @moduletag :integration

  defmodule SyntheticVerifiedSource do
    @moduledoc "In-process test double only; DOES NOT certify signatures."
    def verified_head do
      case Process.get(:fixture_verified, true) do
        true -> {:ok, Process.get(:fixture_head, 0)}
        false -> {:error, :unverified_ledger_prefix}
      end
    end

    def read_page(first, last) do
      {:ok,
       Process.get(:fixture_events, [])
       |> Enum.filter(&(&1.global_seq in first..last))}
    end

    def event_digest(%{event_id: id}),
      do: {:ok, :crypto.hash(:sha256, "fixture-only:" <> id)}
  end

  defmodule StagingHost do
    def environment, do: :staging
    def event_consumer_context, do: {:ok, Process.get(:consumer_context)}
  end

  defmodule ProductionHost do
    def environment, do: :production
    def event_consumer_context, do: {:ok, Process.get(:consumer_context)}
  end

  defp event(seq, type) do
    %{
      type: type,
      global_seq: seq,
      chapter_id: "chapter1",
      event_id: "signed-#{seq}"
    }
  end

  setup do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    conn = start_supervised!({Postgrex, AgentOpsStore.TestConnection.options()})

    context = %{
      home_id: "fixture-home-" <> suffix,
      consumer_id: "agent-consumer-" <> suffix,
      source: SyntheticVerifiedSource,
      ignored_types: ["TestProjectionEvent"]
    }

    Process.put(:consumer_context, context)
    Process.put(:fixture_verified, true)
    Process.put(:fixture_head, 0)
    Process.put(:fixture_events, [])

    %{conn: conn, context: context}
  end

  test "bounded replay records an actual run candidate and no-op event, then resumes", ctx do
    Process.put(:fixture_events, [
      event(1, "TaskAgentRunRequestedV1"),
      event(2, "TestProjectionEvent"),
      event(3, "TaskAgentRunCancelledV1")
    ])

    Process.put(:fixture_head, 3)

    assert {:ok, %{from: 0, to: 1, processed: 1, has_more: true}} =
             EventReplay.drain(ctx.conn, StagingHost, max_events: 1)

    assert {:ok, %{from: 1, to: 2, processed: 1, has_more: true}} =
             EventReplay.drain(ctx.conn, StagingHost, max_events: 1)

    assert {:ok, %{from: 2, to: 3, processed: 1, has_more: false}} =
             EventReplay.drain(ctx.conn, StagingHost, max_events: 1)

    assert {:ok, %{from: 3, to: 3, processed: 0, has_more: false}} =
             EventReplay.drain(ctx.conn, StagingHost)

    assert {:ok, 3} = EventCursor.watermark(ctx.conn, ctx.context.home_id, ctx.context.consumer_id)

    {:ok, %Postgrex.Result{rows: [[candidate_count]]}} =
      Postgrex.query(ctx.conn, """
      SELECT count(*) FROM agent_ops.consumer_effects
      WHERE home_id=$1 AND consumer_id=$2
      """, [ctx.context.home_id, ctx.context.consumer_id])

    assert candidate_count == 2

    {:ok, %Postgrex.Result{rows: [[empty_bundle]]}} =
      Postgrex.query(ctx.conn, """
      SELECT effect_bundle FROM agent_ops.consumer_processed
      WHERE home_id=$1 AND consumer_id=$2 AND global_seq=2
      """, [ctx.context.home_id, ctx.context.consumer_id])

    assert empty_bundle == []
  end

  test "a missing or reordered read page is rejected before the first SQL commit", ctx do
    Process.put(:fixture_head, 3)
    Process.put(:fixture_events, [
      event(1, "TaskAgentRunRequestedV1"),
      event(3, "TaskAgentRunCancelledV1")
    ])

    assert {:error, :ledger_read_gap_or_reorder} =
             EventReplay.drain(ctx.conn, StagingHost)

    assert {:ok, 0} = EventCursor.watermark(ctx.conn, ctx.context.home_id, ctx.context.consumer_id)
  end

  test "unknown event type halts after a durable earlier position, resuming when policy is reviewed", ctx do
    Process.put(:fixture_head, 2)
    Process.put(:fixture_events, [
      event(1, "TaskAgentRunRequestedV1"),
      event(2, "NewUnknownDomainV2")
    ])

    assert {:error, :event_type_not_reviewed} =
             EventReplay.drain(ctx.conn, StagingHost)

    assert {:ok, 1} = EventCursor.watermark(ctx.conn, ctx.context.home_id, ctx.context.consumer_id)

    Process.put(:consumer_context, %{ctx.context | ignored_types: ["NewUnknownDomainV2"]})

    assert {:ok, %{from: 1, to: 2, processed: 1, has_more: false}} =
             EventReplay.drain(ctx.conn, StagingHost)

    assert {:ok, 2} = EventCursor.watermark(ctx.conn, ctx.context.home_id, ctx.context.consumer_id)
  end

  test "a failed signed prefix audit prevents any SQL effect registration", ctx do
    Process.put(:fixture_head, 1)
    Process.put(:fixture_events, [event(1, "TaskAgentRunRequestedV1")])
    Process.put(:fixture_verified, false)

    assert {:error, :unverified_ledger_prefix} = EventReplay.drain(ctx.conn, StagingHost)

    assert {:ok, 0} = EventCursor.watermark(ctx.conn, ctx.context.home_id, ctx.context.consumer_id)
  end

  test "production host, malformed page limits, and unchecked home scopes fail closed", ctx do
    assert {:error, :staging_only} = EventReplay.drain(ctx.conn, ProductionHost)

    assert {:error, :invalid_replay_page_limit} =
             EventReplay.drain(ctx.conn, StagingHost, max_events: 0)

    Process.put(:consumer_context, %{ctx.context | home_id: "../other-home"})
    assert {:error, :invalid_event_cursor_scope} = EventReplay.drain(ctx.conn, StagingHost)
  end
end
