defmodule DispatchWeb.Streams.OperationsTest do
  use ExUnit.Case, async: false

  alias Dispatch.Support.Fixtures
  alias DispatchWeb.Streams.Operations

  @moduletag :integration

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)

    carrier = Fixtures.carrier()
    tenant = carrier.id
    %{participant: driver} = Fixtures.person(tenant, carrier, display_name: "Driver")
    %{participant: dispatcher} = Fixtures.person(tenant, carrier, display_name: "Dispatcher")
    actor = Fixtures.actor(tenant, carrier, dispatcher, "DISPATCHER")

    %{tenant: tenant, driver: driver, actor: actor}
  end

  test "opens with a stable authorized roster fragment", ctx do
    assert {:ok, session, snapshot} = Operations.open(ctx.actor)
    body = IO.iodata_to_binary(snapshot)

    assert session.organization_id == ctx.actor.role_assignment.organization_id
    assert body =~ ~s(id="operations-roster")
    assert body =~ "Driver"
    refute body =~ "latitude"
    refute body =~ "longitude"
  end

  test "heartbeat revalidates and closes on the first tick after revocation", ctx do
    assert {:ok, session, _snapshot} = Operations.open(ctx.actor)
    Fixtures.revoke(ctx.tenant, ctx.actor.role_assignment)

    assert Operations.tick(session, :heartbeat) == {:close, :unauthorized}
  end

  test "refresh revalidates before rendering", ctx do
    assert {:ok, session, _snapshot} = Operations.open(ctx.actor)
    Fixtures.revoke(ctx.tenant, ctx.actor.role_assignment)

    assert Operations.tick(session, :refresh) == {:close, :unauthorized}
  end
end
