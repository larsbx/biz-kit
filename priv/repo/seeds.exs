# Development seed data.
#
# Seeds a carrier tenant and the six human role profiles of Section 23.2, so a
# clean checkout has something to authorize against. Section 21.1 permits
# `authorize?: false` in a seed script; nothing here runs in production.
#
# Run with: mix run priv/repo/seeds.exs

alias Dispatch.Access.SeedManifest
alias Dispatch.Accounts.{Organization, RoleDefinition}

# A transcription error in the manifest would seed a role that grants nothing
# while reading as a grant, so refuse to run rather than produce that state.
case SeedManifest.unknown_capabilities() do
  [] ->
    :ok

  offenders ->
    raise """
    Seed manifests contain capabilities that are not canonical:

    #{Enum.map_join(offenders, "\n", fn {key, unknown} -> "  #{key}: #{Enum.join(unknown, ", ")}" end)}
    """
end

{:ok, carrier} =
  Organization
  |> Ash.Changeset.for_create(:register, %{
    name: "Evergreen Freight",
    kind: :CARRIER,
    status: :ACTIVE
  })
  |> Ash.create(authorize?: false)

# ADR-0005: the tenant is the operating organization.
tenant = carrier.id

definitions =
  Enum.map(SeedManifest.all(), fn manifest ->
    {:ok, definition} =
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
      |> Ash.create(authorize?: false, tenant: tenant)

    definition
  end)

counterparties =
  for {name, kind} <- [
        {"Northwind Brokerage", :BROKER},
        {"Cascade Mills", :SHIPPER},
        {"Harbor Distribution", :RECEIVER}
      ] do
    {:ok, organization} =
      Organization
      |> Ash.Changeset.for_create(:register, %{name: name, kind: kind, status: :ACTIVE})
      |> Ash.create(authorize?: false)

    organization
  end

IO.puts("""
Seeded:
  tenant          #{carrier.name} (#{tenant})
  role profiles   #{definitions |> Enum.map(& &1.key) |> Enum.join(", ")}
  counterparties  #{counterparties |> Enum.map(& &1.name) |> Enum.join(", ")}

No participants or role assignments are seeded. Section 23.2 derives authority
from an assignment, so creating one here would grant access that no test or
operator asked for.
""")
