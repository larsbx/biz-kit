defmodule Dispatch.Accounts.RoleDefinitionImmutabilityTest do
  use ExUnit.Case, async: false

  alias Dispatch.Accounts.RoleDefinition
  alias Dispatch.Support.Fixtures

  @moduletag :integration

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)
    carrier = Fixtures.carrier()
    %{tenant: carrier.id}
  end

  test "re-seeding cannot widen authority already referenced by assignments", ctx do
    original =
      RoleDefinition
      |> Ash.Changeset.for_create(:seed, %{
        tenant_id: ctx.tenant,
        key: "TEST_IMMUTABLE",
        label: "Old label",
        capabilities_json: ["operations.participant.read"],
        constraints_json: %{},
        profile_module: "Dispatch.Access.Roles.Dispatcher"
      })
      |> Ash.create!(authorize?: false, tenant: ctx.tenant)

    reseeded =
      RoleDefinition
      |> Ash.Changeset.for_create(:seed, %{
        tenant_id: ctx.tenant,
        key: "TEST_IMMUTABLE",
        label: "New label",
        capabilities_json: ["audit.read"],
        constraints_json: %{"audit.read" => %{"scope" => "all"}},
        profile_module: "Dispatch.Access.Roles.Admin"
      })
      |> Ash.create!(authorize?: false, tenant: ctx.tenant)

    assert reseeded.id == original.id
    assert reseeded.label == "New label"
    assert reseeded.capabilities_json == original.capabilities_json
    assert reseeded.constraints_json == original.constraints_json
    assert reseeded.profile_module == original.profile_module
  end
end
