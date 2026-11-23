defmodule AgentOpsStore.EventRegistrationsPostgresTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  alias AgentOpsStore.EventRegistrations

  setup do
    conn = start_supervised!({Postgrex, AgentOpsStore.TestConnection.options()})
    subscription = "agent-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    bundle = %{
      seq: 1,
      event_id: "event-1",
      hash: <<1::256>>,
      effect_id: "agent-event:event-1",
      chapter_id: "chapter",
      tenant_id: "tenant",
      project_id: "project"
    }

    %{conn: conn, subscription: subscription, bundle: bundle}
  end

  test "committed effect identity is idempotent and conflicting replay is rejected", c do
    assert {:ok, :new} = EventRegistrations.register(c.conn, c.subscription, c.bundle)
    assert {:ok, :existing} = EventRegistrations.register(c.conn, c.subscription, c.bundle)

    assert {:error, :event_effect_conflict} =
             EventRegistrations.register(c.conn, c.subscription, %{c.bundle | hash: <<2::256>>})

    assert {:error, :event_effect_conflict} =
             EventRegistrations.register(c.conn, c.subscription, %{
               c.bundle
               | event_id: "event-2",
                 effect_id: "agent-event:event-2"
             })
  end

  test "independent connections register one effect under concurrent redelivery", c do
    second =
      start_supervised!(
        Supervisor.child_spec({Postgrex, AgentOpsStore.TestConnection.options()},
          id: :second_registration_connection
        )
      )

    jobs =
      for conn <- [c.conn, second],
          do: Task.async(fn -> EventRegistrations.register(conn, c.subscription, c.bundle) end)

    assert Enum.sort(Enum.map(jobs, &Task.await(&1, 10_000))) == [{:ok, :existing}, {:ok, :new}]
  end

  test "a caller-owned open transaction cannot be mistaken for committed effects", c do
    assert {:ok, {:error, :uncommitted_connection_refused}} =
             Postgrex.transaction(c.conn, fn tx ->
               EventRegistrations.register(tx, c.subscription, c.bundle)
             end)
  end
end
