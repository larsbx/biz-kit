defmodule CoopSubstrate.AgentEventCursorTest do
  use CoopSubstrate.LogCase, async: false
  alias CoopSubstrate.{AgentEventCursor, AgentStagingFixture, AgentStagingSQL, Log}
  alias AgentOpsStore.EventCursor

  defmodule Staging do
    def environment, do: :staging
  end

  defmodule Production do
    def environment, do: :production
  end

  setup do
    AgentStagingSQL.setup!()
    ctx = AgentStagingFixture.prepare()
    assert {:ok, _} = Log.append(AgentStagingFixture.request(ctx))

    conn =
      start_supervised!(
        {Postgrex, Application.fetch_env!(:coop_substrate, CoopSubstrate.EventStore)}
      )

    %{conn: conn, home: "home-" <> CoopSubstrate.ULID.generate(), subscriber: "agent-v1"}
  end

  defp drain(c, remaining \\ 100)
  defp drain(_c, 0), do: flunk("bounded cursor did not catch up")

  defp drain(c, n) do
    assert {:ok, result} = AgentEventCursor.catch_up(c.conn, c.home, c.subscriber, Staging, 3)
    if result.caught_up, do: result, else: drain(c, n - 1)
  end

  test "bounded committed replay catches up without any notification or launch", c do
    assert {:ok, %{cursor: 3, caught_up: false}} =
             AgentEventCursor.catch_up(c.conn, c.home, c.subscriber, Staging, 3)

    restart_log()
    result = drain(c)
    assert result.cursor == Log.head().global_seq
    assert {:ok, %{seq: seq}} = EventCursor.snapshot(c.conn, c.home, c.subscriber)

    assert %{rows: [[^seq]]} =
             Postgrex.query!(
               c.conn,
               "SELECT count(*) FROM agent_ops.event_registrations WHERE home_id=$1 AND subscriber=$2",
               [c.home, c.subscriber]
             )

    assert %{rows: [[0]]} =
             Postgrex.query!(c.conn, "SELECT count(*) FROM agent_ops.execution_attempts", [])

    # Repeat after a completed commit, as if acknowledgment was lost.
    assert AgentEventCursor.catch_up(c.conn, c.home, c.subscriber, Staging, 3) == {:ok, result}
    actor = new_member("author")

    {:ok, _} =
      Log.append(
        signed_event(actor, "TestProjectionEvent", %{"note" => "lost hint", "amount_minor" => 0})
      )

    later = drain(c)
    assert later.cursor == seq + 1

    assert %{rows: [[nil]]} =
             Postgrex.query!(
               c.conn,
               "SELECT effect_id FROM agent_ops.event_registrations WHERE home_id=$1 AND global_seq=$2",
               [c.home, later.cursor]
             )
  end

  test "production and invalid page sizes are refused without a checkpoint", c do
    assert {:error, :staging_only} =
             AgentEventCursor.catch_up(c.conn, c.home, c.subscriber, Production)

    assert {:error, :invalid_cursor_page_size} =
             AgentEventCursor.catch_up(c.conn, c.home, c.subscriber, Staging, 1001)

    assert {:ok, %{seq: 0}} = EventCursor.snapshot(c.conn, c.home, c.subscriber)
  end

  test "producer append between bounded pages is discovered on the next pass", c do
    assert {:ok, %{cursor: 1, observed_head: old_head}} =
             AgentEventCursor.catch_up(c.conn, c.home, c.subscriber, Staging, 1)

    actor = new_member("author")

    {:ok, _} =
      Log.append(
        signed_event(actor, "TestProjectionEvent", %{
          "note" => "producer append",
          "amount_minor" => 0
        })
      )

    result = drain(c)
    assert result.cursor == old_head + 1
    assert result.caught_up
  end

  test "a checkpoint anchored to another history is refused", c do
    fake = %{
      seq: 1,
      event_id: "unrelated",
      prev_hash: nil,
      hash: <<7::256>>,
      effect_id: nil,
      chapter_id: nil,
      tenant_id: nil,
      project_id: nil
    }

    assert {:ok, :new} =
             EventCursor.commit(c.conn, c.home, c.subscriber, %{seq: 0, hash: nil}, fake)

    assert {:error, :cursor_history_mismatch} =
             AgentEventCursor.catch_up(c.conn, c.home, c.subscriber, Staging)
  end
end
