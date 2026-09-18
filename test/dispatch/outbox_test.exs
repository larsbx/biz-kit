defmodule Dispatch.OutboxTest do
  use ExUnit.Case, async: false

  alias Dispatch.Audit.AuditEvent
  alias Dispatch.Operations.Declarations
  alias Dispatch.Outbox.{Event, Publisher}
  alias Dispatch.Support.Fixtures

  import Ecto.Query, only: [from: 2]

  @moduletag :integration

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)

    carrier = Fixtures.carrier()
    tenant = carrier.id
    %{participant: driver} = Fixtures.person(tenant, carrier)
    actor = Fixtures.actor(tenant, carrier, driver, "DRIVER")

    %{tenant: tenant, driver: driver, actor: actor}
  end

  test "status, audit, and both stream notifications commit together", ctx do
    assert {:ok, :created, event} =
             Declarations.declare(ctx.actor, %{
               status: "AVAILABLE",
               occurred_at: DateTime.utc_now()
             })

    assert [_audit] =
             AuditEvent
             |> Ash.Query.for_read(:for_subject, %{
               subject_type: "participant",
               subject_id: ctx.driver.id
             })
             |> Ash.read!(authorize?: false, tenant: ctx.tenant)

    rows =
      from(e in Event, where: e.payload["event_id"] == ^event.id)
      |> Dispatch.Repo.all()

    assert Enum.sort(Enum.map(rows, & &1.topic)) ==
             Enum.sort([
               "operations:#{ctx.actor.role_assignment.organization_id}",
               "participant:#{ctx.driver.id}"
             ])
  end

  test "publisher emits committed refreshes and marks the row", ctx do
    topic = "participant:#{ctx.driver.id}"
    Phoenix.PubSub.subscribe(Dispatch.PubSub, topic)

    row = %Event{
      id: Ash.UUID.generate(),
      tenant_id: ctx.tenant,
      topic: topic,
      event_type: "test",
      payload: %{"event_id" => Ash.UUID.generate()},
      occurred_at: DateTime.utc_now()
    }

    Dispatch.Repo.insert!(row)
    assert Publisher.publish_pending() >= 1
    assert_receive {:outbox, %{"event_id" => _}}

    published = Dispatch.Repo.get!(Event, row.id)
    assert published.published_at
    assert published.attempt_count == 1
  end
end
