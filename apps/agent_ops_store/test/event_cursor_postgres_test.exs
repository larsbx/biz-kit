defmodule AgentOpsStore.EventCursorPostgresTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  alias AgentOpsStore.EventCursor

  setup do
    conn = start_supervised!({Postgrex, AgentOpsStore.TestConnection.options()})
    home = "cursor-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    bundle = %{
      seq: 1,
      event_id: "event-1",
      prev_hash: nil,
      hash: <<1::256>>,
      effect_id: "agent-event:event-1",
      chapter_id: "chapter",
      tenant_id: "tenant",
      project_id: "project"
    }

    %{conn: conn, home: home, subscriber: "agent-v1", bundle: bundle, zero: %{seq: 0, hash: nil}}
  end

  test "effect registrations precede the cursor and retries preserve exact identity", c do
    assert {:ok, :new} = EventCursor.commit(c.conn, c.home, c.subscriber, c.zero, c.bundle)
    assert {:ok, :existing} = EventCursor.commit(c.conn, c.home, c.subscriber, c.zero, c.bundle)

    assert {:error, :cursor_conflict} =
             EventCursor.commit(c.conn, c.home, c.subscriber, c.zero, %{
               c.bundle
               | hash: <<2::256>>
             })

    assert {:ok, %{seq: 1, hash: <<1::256>>}} = EventCursor.snapshot(c.conn, c.home, c.subscriber)

    assert %{rows: [[1]]} =
             Postgrex.query!(
               c.conn,
               "SELECT count(*) FROM agent_ops.event_registrations WHERE home_id=$1",
               [c.home]
             )
  end

  test "outer rollback leaves neither effects nor advanced cursor", c do
    assert {:error, :injected_failure} =
             Postgrex.transaction(c.conn, fn tx ->
               assert {:ok, :new} = EventCursor.commit(tx, c.home, c.subscriber, c.zero, c.bundle)
               Postgrex.rollback(tx, :injected_failure)
             end)

    assert {:ok, %{seq: 0, hash: nil}} = EventCursor.snapshot(c.conn, c.home, c.subscriber)

    assert %{rows: [[0]]} =
             Postgrex.query!(
               c.conn,
               "SELECT count(*) FROM agent_ops.event_registrations WHERE home_id=$1",
               [c.home]
             )
  end

  test "independent connections racing one checkpoint register once", c do
    second =
      start_supervised!(
        Supervisor.child_spec({Postgrex, AgentOpsStore.TestConnection.options()},
          id: :second_cursor_connection
        )
      )

    jobs =
      for conn <- [c.conn, second],
          do:
            Task.async(fn -> EventCursor.commit(conn, c.home, c.subscriber, c.zero, c.bundle) end)

    assert Enum.sort(Enum.map(jobs, &Task.await(&1, 10_000))) == [{:ok, :existing}, {:ok, :new}]
    assert {:ok, %{seq: 1}} = EventCursor.snapshot(second, c.home, c.subscriber)
  end

  test "database connection loss before transaction commit cannot leave a checkpoint", c do
    second =
      start_supervised!(
        Supervisor.child_spec({Postgrex, AgentOpsStore.TestConnection.options()},
          id: :crash_observer
        )
      )

    %{rows: [[backend]]} = Postgrex.query!(c.conn, "SELECT pg_backend_pid()", [])
    parent = self()

    job =
      Task.async(fn ->
        try do
          Postgrex.transaction(c.conn, fn tx ->
            assert {:ok, :new} = EventCursor.commit(tx, c.home, c.subscriber, c.zero, c.bundle)
            send(parent, :inside_uncommitted_cursor_transaction)

            receive do
              :release -> :ok
            end
          end)
        rescue
          _ -> {:error, :connection_lost}
        catch
          :exit, _ -> {:error, :connection_lost}
        end
      end)

    assert_receive :inside_uncommitted_cursor_transaction, 2000

    assert %{rows: [[true]]} =
             Postgrex.query!(second, "SELECT pg_terminate_backend($1,5000)", [backend])

    send(job.pid, :release)
    assert {:error, _} = Task.await(job, 10_000)
    assert {:ok, %{seq: 0, hash: nil}} = EventCursor.snapshot(second, c.home, c.subscriber)

    assert %{rows: [[0]]} =
             Postgrex.query!(
               second,
               "SELECT count(*) FROM agent_ops.event_registrations WHERE home_id=$1",
               [c.home]
             )
  end
end
