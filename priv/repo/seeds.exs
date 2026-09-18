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

# A load with two stops and its party relationships, so a developer has
# something to authorize against. Section 22.2 makes the party rows the second
# half of every LOAD- and STOP-scoped decision, and a tenant with roles but no
# relationships cannot exercise that path at all.
[broker_org, shipper_org, receiver_org] = counterparties

{:ok, demo_load} =
  Dispatch.Fleet.Load
  |> Ash.Changeset.for_create(:create_load, %{
    tenant_id: tenant,
    carrier_organization_id: carrier.id,
    broker_organization_id: broker_org.id,
    external_reference: "NW-48213",
    commodity_text: "Palletised dry goods",
    status: :BOOKED,
    currency: "USD",
    agreed_rate_minor: 185_000
  })
  |> Ash.create(authorize?: false, tenant: tenant)

stops =
  for {kind, sequence, address, org} <- [
        {:PICKUP, 1, "1 Mill Road, Cascade WA", shipper_org},
        {:DELIVERY, 2, "400 Harbor Way, Portland OR", receiver_org}
      ] do
    {:ok, stop} =
      Dispatch.Fleet.Stop
      |> Ash.Changeset.for_create(:add, %{
        tenant_id: tenant,
        load_id: demo_load.id,
        sequence: sequence,
        kind: kind,
        address_text: address
      })
      |> Ash.create(authorize?: false, tenant: tenant)

    {:ok, _stop_party} =
      Dispatch.Fleet.StopParty
      |> Ash.Changeset.for_create(:add, %{
        tenant_id: tenant,
        stop_id: stop.id,
        organization_id: org.id,
        relationship: if(kind == :PICKUP, do: :SHIPPER, else: :RECEIVER),
        starts_at: DateTime.utc_now()
      })
      |> Ash.create(authorize?: false, tenant: tenant)

    stop
  end

for {org, relationship} <- [
      {broker_org, :BROKER},
      {shipper_org, :SHIPPER},
      {receiver_org, :RECEIVER},
      {carrier, :CARRIER}
    ] do
  {:ok, _load_party} =
    Dispatch.Fleet.LoadParty
    |> Ash.Changeset.for_create(:add, %{
      tenant_id: tenant,
      load_id: demo_load.id,
      organization_id: org.id,
      relationship: relationship,
      starts_at: DateTime.utc_now()
    })
    |> Ash.create(authorize?: false, tenant: tenant)
end

IO.puts("""
Seeded:
  tenant          #{carrier.name} (#{tenant})
  role profiles   #{definitions |> Enum.map(& &1.key) |> Enum.join(", ")}
  counterparties  #{counterparties |> Enum.map(& &1.name) |> Enum.join(", ")}
  load            #{demo_load.external_reference} with #{length(stops)} stops and 4 load parties

No participants or role assignments are seeded. Section 23.2 derives authority
from an assignment, so creating one here would grant access that no test or
operator asked for.
""")
