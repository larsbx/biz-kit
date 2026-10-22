# The end-to-end stack's fixtures (scripts/e2e-stack.sh; d-patch's e2e/).
# Development only: Section 21.1 permits `authorize?: false` in a seed script,
# and nothing here runs in production.
#
#   mix run priv/repo/e2e.exs seed <stack.json>     a carrier, its roles, a
#       driver, a dispatcher and a courier bound to biz-kit principals; writes
#       what the tests need (and the identity bindings the server boots with)
#   mix run priv/repo/e2e.exs revoke <tenant> <role_assignment_id>
#       ends an assignment, as an administrator would (scenario 16)

alias BizKit.Identity.Principal
alias Dispatch.Access.SeedManifest
alias Dispatch.Accounts.{Organization, Participant, RoleAssignment, RoleDefinition, User}

defmodule Dispatch.E2E do
  @moduledoc false

  # The development provider's issuer (BizKit.Identity.Providers.Development).
  @issuer "biz-kit-development"

  # Scenario 14's second field role: the test profile (compiled in dev for this),
  # with the driver's self-service capabilities it has features for. Nothing
  # else is new: the same participant, device, assignment and status resources.
  @courier %{
    key: "COURIER",
    label: "Courier",
    profile_module: Dispatch.Support.Roles.Courier,
    scope_type: :SELF,
    capabilities:
      ~w(profile.read.self assignment.read.self status.declare.self communications.read.self),
    constraints: %{
      "status.declare.self" => ["self_only"],
      "assignment.read.self" => ["self_only", "active_assignment_only"],
      "communications.read.self" => ["self_only"]
    }
  }

  def seed(path) do
    {:ok, carrier} =
      Organization
      |> Ash.Changeset.for_create(:register, %{
        name: "E2E Freight",
        kind: :CARRIER,
        status: :ACTIVE
      })
      |> Ash.create(authorize?: false)

    tenant = carrier.id

    definitions =
      Map.new([@courier | SeedManifest.all()], &{&1.key, {&1, definition(tenant, &1)}})

    people =
      for {name, key} <- [
            {"driver", "DRIVER"},
            {"dispatcher", "DISPATCHER"},
            {"courier", "COURIER"}
          ],
          into: %{} do
        {name, person(tenant, carrier, name, definitions[key])}
      end

    stack = %{
      tenant_id: tenant,
      people: people,
      bindings:
        for(
          {_name, p} <- people,
          do: %{issuer: @issuer, subject: p.subject, principal: p.principal}
        ),
      development_sign_in: Enum.map_join(people, ",", fn {name, p} -> "#{name}=#{p.subject}" end)
    }

    File.write!(path, JSON.encode!(stack))
    IO.puts("Seeded #{map_size(people)} people in #{tenant}; wrote #{path}")
  end

  def revoke(tenant, assignment_id) do
    RoleAssignment
    |> Ash.get!(assignment_id, authorize?: false, tenant: tenant)
    |> Ash.Changeset.for_update(:revoke, %{})
    |> Ash.update!(authorize?: false, tenant: tenant)

    IO.puts("Revoked #{assignment_id}")
  end

  defp definition(tenant, manifest) do
    RoleDefinition
    |> Ash.Changeset.for_create(:seed, %{
      tenant_id: tenant,
      key: manifest.key,
      label: manifest.label,
      capability_schema_version: 1,
      capabilities_json: manifest.capabilities,
      constraints_json: manifest.constraints,
      profile_module: inspect(manifest.profile_module),
      status: :ACTIVE
    })
    |> Ash.create!(authorize?: false, tenant: tenant)
  end

  # A person signs in as a biz-kit principal; dispatch knows them by it.
  defp person(tenant, carrier, name, {manifest, definition}) do
    principal = Principal.new_id()
    subject = "e2e-#{name}-#{System.unique_integer([:positive])}"

    user =
      User
      |> Ash.Changeset.for_create(:register, %{oidc_subject: principal, display_name: name})
      |> Ash.create!(authorize?: false)

    participant =
      Participant
      |> Ash.Changeset.for_create(:enroll, %{
        tenant_id: tenant,
        user_id: user.id,
        home_organization_id: carrier.id,
        public_name: String.capitalize(name)
      })
      |> Ash.create!(authorize?: false, tenant: tenant)

    assignment =
      RoleAssignment
      |> Ash.Changeset.for_create(:grant, %{
        tenant_id: tenant,
        principal_type: :PARTICIPANT,
        principal_id: participant.id,
        organization_id: carrier.id,
        role_definition_id: definition.id,
        scope_type: manifest.scope_type,
        starts_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      })
      |> Ash.create!(authorize?: false, tenant: tenant)

    %{
      provider: name,
      subject: subject,
      principal: principal,
      participant_id: participant.id,
      role_key: manifest.key,
      role_assignment_id: assignment.id
    }
  end
end

case System.argv() do
  ["seed", path] -> Dispatch.E2E.seed(path)
  ["revoke", tenant, assignment_id] -> Dispatch.E2E.revoke(tenant, assignment_id)
  _ -> raise "usage: mix run priv/repo/e2e.exs seed <stack.json> | revoke <tenant> <assignment>"
end
