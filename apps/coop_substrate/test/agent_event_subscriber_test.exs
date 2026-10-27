defmodule CoopSubstrate.AgentEventSubscriberTest do
  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.{
    AgentEventDelivery,
    AgentEventSubscriber,
    AgentStagingFixture,
    AgentStagingSQL,
    EventStore,
    Log
  }

  alias AgentOpsStore.EventRegistrations
  alias Elixir.EventStore.RecordedEvent

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

    name = "agent-native-" <> CoopSubstrate.ULID.generate()
    on_exit(fn -> EventStore.unsubscribe_from_stream("ledger", name) end)
    %{conn: conn, name: name}
  end

  defp checkpoint(conn, name) do
    case Postgrex.query!(
           conn,
           "SELECT last_seen FROM subscriptions WHERE stream_uuid='ledger' AND subscription_name=$1",
           [name]
         ).rows do
      [[n]] -> n || 0
      [] -> 0
    end
  end

  defp await_checkpoint(conn, name, n, left \\ 500)
  defp await_checkpoint(_, _, _, 0), do: flunk("native subscription did not checkpoint")

  defp await_checkpoint(conn, name, n, left) do
    if checkpoint(conn, name) == n,
      do: :ok,
      else:
        (
          Process.sleep(10)
          await_checkpoint(conn, name, n, left - 1)
        )
  end

  defp subscribe(name) do
    {:ok, sub} =
      EventStore.subscribe_to_stream("ledger", name, self(),
        start_from: :origin,
        transient: false,
        buffer_size: 1,
        concurrency_limit: 1,
        checkpoint_threshold: 1,
        max_size: 100
      )

    assert_receive {:subscribed, ^sub}, 5000
    sub
  end

  defp flush_deliveries do
    receive do
      {:events, _} -> flush_deliveries()
    after
      0 -> :ok
    end
  end

  test "native subscription catches up without pg hints and resumes its own checkpoint", c do
    pid =
      start_supervised!(
        {AgentEventSubscriber, host: Staging, connection: c.conn, subscription_name: c.name}
      )

    head = Log.head().global_seq
    await_checkpoint(c.conn, c.name, head)

    assert %{rows: [[^head]]} =
             Postgrex.query!(
               c.conn,
               "SELECT count(*) FROM agent_ops.event_effect_registrations WHERE subscription_name=$1",
               [c.name]
             )

    send(pid, {:coop_ledger, [:forged]})

    send(
      pid,
      {:events,
       [
         %RecordedEvent{
           stream_uuid: "ledger",
           event_number: head + 99,
           stream_version: head + 99,
           data: "forged"
         }
       ]}
    )

    :sys.get_state(pid)
    assert checkpoint(c.conn, c.name) == head
    stop_supervised!(AgentEventSubscriber)
    EventStore.unsubscribe_from_stream("ledger", c.name)
    restart_log()

    {:ok, _} =
      Log.append(
        signed_event(new_member("author"), "TestProjectionEvent", %{
          "note" => "offline",
          "amount_minor" => 0
        })
      )

    start_supervised!(
      {AgentEventSubscriber, host: Staging, connection: c.conn, subscription_name: c.name}
    )

    await_checkpoint(c.conn, c.name, head + 1)

    assert %{rows: [[0]]} =
             Postgrex.query!(c.conn, "SELECT count(*) FROM agent_ops.execution_attempts", [])

    assert %{rows: [[nil]]} =
             Postgrex.query!(
               c.conn,
               "SELECT effect_id FROM agent_ops.event_effect_registrations WHERE subscription_name=$1 AND global_seq=$2",
               [c.name, head + 1]
             )
  end

  test "commit followed by crash before ack is redelivered by native EventStore", c do
    sub = subscribe(c.name)
    assert_receive {:events, [%RecordedEvent{event_number: 1}]}, 5000
    assert checkpoint(c.conn, c.name) == 0
    {:ok, bundle} = AgentEventSubscriber.read(1)
    assert {:ok, :new} = EventRegistrations.register(c.conn, c.name, bundle)
    # Kill the native subscription before acknowledging, then reconnect with
    # exactly the same name. No application cursor participates in recovery.
    monitor = Process.monitor(sub)
    Process.exit(sub, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^sub, :killed}, 5000
    again = subscribe(c.name)
    assert_receive {:events, [%RecordedEvent{event_number: 1}]}, 5000
    assert {:ok, :existing} = EventRegistrations.register(c.conn, c.name, bundle)
    assert :ok = EventStore.ack(again, 1)
    await_checkpoint(c.conn, c.name, 1)
    EventStore.unsubscribe_from_stream("ledger", c.name)
    flush_deliveries()
    subscribe(c.name)
    assert_receive {:events, [%RecordedEvent{event_number: 2}]}, 5000
  end

  test "registration failure leaves native checkpoint unacknowledged", c do
    sub = subscribe(c.name)
    assert_receive {:events, [%RecordedEvent{event_number: 1}]}, 5000

    ports = %{
      read: &AgentEventSubscriber.read/1,
      register: fn _ -> {:error, :injected_db_failure} end,
      ack: &EventStore.ack(sub, &1)
    }

    assert {:error, :injected_db_failure} = AgentEventDelivery.deliver(1, ports)
    assert checkpoint(c.conn, c.name) == 0
  end

  test "staging adapter cannot start in production", c do
    assert {:error, :staging_only} =
             AgentEventSubscriber.start_link(
               host: Production,
               connection: c.conn,
               subscription_name: c.name
             )

    assert checkpoint(c.conn, c.name) == 0
  end
end
