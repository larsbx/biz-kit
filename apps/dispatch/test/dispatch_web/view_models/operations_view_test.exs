defmodule DispatchWeb.ViewModels.OperationsViewTest do
  use ExUnit.Case, async: false

  alias Dispatch.Support.Fixtures
  alias DispatchWeb.ViewModels.OperationsView

  @moduletag :integration

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)

    carrier = Fixtures.carrier()
    tenant = carrier.id
    %{participant: dispatcher} = Fixtures.person(tenant, carrier, display_name: "Dispatcher")
    actor = Fixtures.actor(tenant, carrier, dispatcher, "DISPATCHER")

    %{tenant: tenant, carrier: carrier, actor: actor}
  end

  test "contains only active participants from the selected carrier", ctx do
    %{participant: visible} = Fixtures.person(ctx.tenant, ctx.carrier, display_name: "Visible")
    elsewhere = Fixtures.carrier()
    Fixtures.person(elsewhere.id, elsewhere, display_name: "Hidden")

    assert {:ok, view} = OperationsView.build(ctx.actor)
    ids = Enum.map(view.participants, & &1.participant_id)

    assert visible.id in ids
    assert Enum.all?(view.participants, &(&1.public_name != "Hidden"))
  end

  test "an admin-only assignment cannot build the operational roster", ctx do
    %{participant: admin} = Fixtures.person(ctx.tenant, ctx.carrier)
    admin_actor = Fixtures.actor(ctx.tenant, ctx.carrier, admin, "ADMIN")

    assert OperationsView.build(admin_actor) == {:error, :not_found}
  end

  test "revocation terminates roster access", ctx do
    Fixtures.revoke(ctx.tenant, ctx.actor.role_assignment)
    assert OperationsView.build(ctx.actor) == {:error, :not_found}
  end
end
