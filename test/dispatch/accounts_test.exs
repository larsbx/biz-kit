defmodule Dispatch.AccountsTest do
  @moduledoc """
  Database-backed behaviour of the identity and access resources.

  These need real PostgreSQL because what they assert lives in constraints and
  in Ash's tenant filtering, not in Elixir: a partial unique index, a global
  index on a tenant-scoped table, and cross-tenant isolation are all things an
  in-memory test would simply agree with.
  """

  use ExUnit.Case, async: false

  alias Dispatch.Access.SeedManifest

  alias Dispatch.Accounts.{
    Contact,
    Device,
    Organization,
    Participant,
    RoleAssignment,
    RoleDefinition,
    User
  }

  require Ash.Query

  @moduletag :integration

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp organization(kind \\ :CARRIER) do
    Organization
    |> Ash.Changeset.for_create(:register, %{name: unique("Org"), kind: kind})
    |> Ash.create!(authorize?: false)
  end

  defp user do
    User
    |> Ash.Changeset.for_create(:register, %{
      oidc_subject: unique("sub"),
      display_name: "Test Person"
    })
    |> Ash.create!(authorize?: false)
  end

  defp participant(tenant, user, org) do
    Participant
    |> Ash.Changeset.for_create(:enroll, %{
      tenant_id: tenant,
      user_id: user.id,
      home_organization_id: org.id,
      public_name: "Test Person"
    })
    |> Ash.create!(authorize?: false, tenant: tenant)
  end

  defp role_definition(tenant, key) do
    {:ok, manifest} = SeedManifest.fetch(key)

    RoleDefinition
    |> Ash.Changeset.for_create(:seed, %{
      tenant_id: tenant,
      key: manifest.key,
      label: manifest.label,
      capabilities_json: manifest.capabilities,
      constraints_json: manifest.constraints,
      profile_module: inspect(manifest.profile_module)
    })
    |> Ash.create!(authorize?: false, tenant: tenant)
  end

  describe "ADR-0005 multitenancy" do
    test "a participant is invisible from another tenant" do
      carrier_a = organization()
      carrier_b = organization()
      person = user()

      participant(carrier_a.id, person, carrier_a)

      assert [_one] = Ash.read!(Participant, authorize?: false, tenant: carrier_a.id)
      assert [] == Ash.read!(Participant, authorize?: false, tenant: carrier_b.id)
    end

    test "one person working for two carriers is one user and two participants" do
      carrier_a = organization()
      carrier_b = organization()
      person = user()

      participant(carrier_a.id, person, carrier_a)
      participant(carrier_b.id, person, carrier_b)

      assert [a] = Ash.read!(Participant, authorize?: false, tenant: carrier_a.id)
      assert [b] = Ash.read!(Participant, authorize?: false, tenant: carrier_b.id)

      assert a.user_id == b.user_id
      refute a.id == b.id
    end

    test "role definitions do not leak across tenants" do
      carrier_a = organization()
      carrier_b = organization()

      role_definition(carrier_a.id, "DRIVER")

      assert [_one] = Ash.read!(RoleDefinition, authorize?: false, tenant: carrier_a.id)
      assert [] == Ash.read!(RoleDefinition, authorize?: false, tenant: carrier_b.id)
    end
  end

  describe "Section 22.1 uniqueness" do
    test "oidc_subject is unique globally" do
      subject = unique("sub")

      User
      |> Ash.Changeset.for_create(:register, %{oidc_subject: subject, display_name: "First"})
      |> Ash.create!(authorize?: false)

      # The create action upserts on this identity, so a second registration
      # updates the existing user rather than creating a rival identity.
      second =
        User
        |> Ash.Changeset.for_create(:register, %{oidc_subject: subject, display_name: "Renamed"})
        |> Ash.create!(authorize?: false)

      assert second.display_name == "Renamed"

      assert [_only_one] =
               User |> Ash.Query.filter(oidc_subject == ^subject) |> Ash.read!(authorize?: false)
    end

    test "installation_id is unique across tenants, not within one" do
      # Section 22.1 lists devices.installation_id unqualified while qualifying
      # contacts.phone_e164 as "within a tenant". One handset must not be
      # registrable under two tenants at once.
      carrier_a = organization()
      carrier_b = organization()
      person = user()
      participant_a = participant(carrier_a.id, person, carrier_a)
      participant_b = participant(carrier_b.id, person, carrier_b)
      installation = unique("install")

      Device
      |> Ash.Changeset.for_create(:register, %{
        tenant_id: carrier_a.id,
        participant_id: participant_a.id,
        installation_id: installation,
        public_key: "key-a"
      })
      |> Ash.create!(authorize?: false, tenant: carrier_a.id)

      assert {:error, error} =
               Device
               |> Ash.Changeset.for_create(:register, %{
                 tenant_id: carrier_b.id,
                 participant_id: participant_b.id,
                 installation_id: installation,
                 public_key: "key-b"
               })
               |> Ash.create(authorize?: false, tenant: carrier_b.id)

      assert Exception.message(error) =~ ~r/installation_id|unique/i
    end

    test "an active contact phone is unique within a tenant but free across tenants" do
      carrier_a = organization()
      carrier_b = organization()
      phone = "+15005550#{:rand.uniform(899) + 100}"

      add_contact = fn tenant, org ->
        Contact
        |> Ash.Changeset.for_create(:add, %{
          tenant_id: tenant,
          organization_id: org.id,
          kind: :BROKER,
          name: "Desk",
          phone_e164: phone
        })
        |> Ash.create(authorize?: false, tenant: tenant)
      end

      assert {:ok, first} = add_contact.(carrier_a.id, carrier_a)
      assert {:error, _duplicate} = add_contact.(carrier_a.id, carrier_a)

      # The same number in another tenant is a different counterparty record.
      assert {:ok, _other_tenant} = add_contact.(carrier_b.id, carrier_b)

      # Archiving frees the number, because the index is partial on ACTIVE.
      first
      |> Ash.Changeset.for_update(:archive, %{})
      |> Ash.update!(authorize?: false, tenant: carrier_a.id)

      assert {:ok, _reused} = add_contact.(carrier_a.id, carrier_a)
    end

    test "a revoked role assignment does not block re-granting the same authority" do
      carrier = organization()
      person = user()
      subject = participant(carrier.id, person, carrier)
      definition = role_definition(carrier.id, "DRIVER")

      grant = fn ->
        RoleAssignment
        |> Ash.Changeset.for_create(:grant, %{
          tenant_id: carrier.id,
          principal_type: :PARTICIPANT,
          principal_id: subject.id,
          organization_id: carrier.id,
          role_definition_id: definition.id,
          scope_type: :SELF,
          starts_at: DateTime.utc_now()
        })
        |> Ash.create(authorize?: false, tenant: carrier.id)
      end

      assert {:ok, first} = grant.()
      assert {:error, _duplicate} = grant.()

      first
      |> Ash.Changeset.for_update(:revoke, %{})
      |> Ash.update!(authorize?: false, tenant: carrier.id)

      assert {:ok, _regranted} = grant.()
    end
  end

  describe "Section 22 optimistic concurrency" do
    test "two stale copies cannot both revoke the same assignment" do
      carrier = organization()
      person = user()
      subject = participant(carrier.id, person, carrier)
      definition = role_definition(carrier.id, "DRIVER")

      assignment =
        RoleAssignment
        |> Ash.Changeset.for_create(:grant, %{
          tenant_id: carrier.id,
          principal_type: :PARTICIPANT,
          principal_id: subject.id,
          organization_id: carrier.id,
          role_definition_id: definition.id,
          scope_type: :SELF,
          starts_at: DateTime.utc_now()
        })
        |> Ash.create!(authorize?: false, tenant: carrier.id)

      first_copy = assignment
      stale_copy = assignment

      updated =
        first_copy
        |> Ash.Changeset.for_update(:revoke, %{expected_version: 0})
        |> Ash.update!(authorize?: false, tenant: carrier.id)

      assert updated.version == 1

      assert {:error, error} =
               stale_copy
               |> Ash.Changeset.for_update(:revoke, %{expected_version: 0})
               |> Ash.update(authorize?: false, tenant: carrier.id)

      assert Exception.message(error) =~ ~r/stale|changed/i
    end
  end

  describe "Section 23.2 role definition constraints" do
    test "a manifest with a non-canonical capability is rejected" do
      carrier = organization()

      assert {:error, error} =
               RoleDefinition
               |> Ash.Changeset.for_create(:seed, %{
                 tenant_id: carrier.id,
                 key: "CUSTOM",
                 label: "Custom",
                 capabilities_json: ["load.read", "load.delete.everything"],
                 profile_module: inspect(Dispatch.Access.Roles.Dispatcher)
               })
               |> Ash.create(authorize?: false, tenant: carrier.id)

      assert Exception.message(error) =~ "load.delete.everything"
    end

    test "a profile module outside the allowlist is rejected" do
      # Section 23.2: database content cannot name or load arbitrary code.
      carrier = organization()

      assert {:error, error} =
               RoleDefinition
               |> Ash.Changeset.for_create(:seed, %{
                 tenant_id: carrier.id,
                 key: "ROGUE",
                 label: "Rogue",
                 capabilities_json: ["load.read"],
                 profile_module: "Elixir.Kernel"
               })
               |> Ash.create(authorize?: false, tenant: carrier.id)

      assert Exception.message(error) =~ "ROLE_PROFILE_MODULE_ALLOWLIST"
    end

    test "a module that does not exist at all is rejected" do
      carrier = organization()

      assert {:error, _error} =
               RoleDefinition
               |> Ash.Changeset.for_create(:seed, %{
                 tenant_id: carrier.id,
                 key: "MISSING",
                 label: "Missing",
                 capabilities_json: ["load.read"],
                 profile_module: "Elixir.Dispatch.Access.Roles.DoesNotExist"
               })
               |> Ash.create(authorize?: false, tenant: carrier.id)
    end
  end

  describe "Section 23.2 service principals" do
    test "a SERVICE principal cannot hold self-service capabilities" do
      # Otherwise an agent runtime or a background job could declare a status or
      # decide a proposal on a person's behalf, which Sections 8.3 and 9 forbid.
      carrier = organization()
      driver_definition = role_definition(carrier.id, "DRIVER")

      assert {:error, error} =
               RoleAssignment
               |> Ash.Changeset.for_create(:grant, %{
                 tenant_id: carrier.id,
                 principal_type: :SERVICE,
                 principal_id: Ash.UUID.generate(),
                 organization_id: carrier.id,
                 role_definition_id: driver_definition.id,
                 scope_type: :ORGANIZATION,
                 starts_at: DateTime.utc_now()
               })
               |> Ash.create(authorize?: false, tenant: carrier.id)

      assert Exception.message(error) =~ "status.declare.self"
    end

    test "an unreadable role definition denies the grant rather than allowing it" do
      # The check has to fail closed. An earlier version collapsed every failure
      # mode into "allow", so a missing definition row would have let a SERVICE
      # principal be granted self-service capabilities without anything being
      # read at all.
      carrier = organization()
      person = user()
      subject = participant(carrier.id, person, carrier)

      assert {:error, error} =
               RoleAssignment
               |> Ash.Changeset.for_create(:grant, %{
                 tenant_id: carrier.id,
                 principal_type: :SERVICE,
                 principal_id: subject.id,
                 organization_id: carrier.id,
                 role_definition_id: Ash.UUID.generate(),
                 scope_type: :ORGANIZATION,
                 starts_at: DateTime.utc_now()
               })
               |> Ash.create(authorize?: false, tenant: carrier.id)

      assert Exception.message(error) =~ "could not be read"
    end

    test "a SERVICE principal may hold a non-self-service role" do
      carrier = organization()
      dispatcher_definition = role_definition(carrier.id, "DISPATCHER")

      assert {:ok, _assignment} =
               RoleAssignment
               |> Ash.Changeset.for_create(:grant, %{
                 tenant_id: carrier.id,
                 principal_type: :SERVICE,
                 principal_id: Ash.UUID.generate(),
                 organization_id: carrier.id,
                 role_definition_id: dispatcher_definition.id,
                 scope_type: :ORGANIZATION,
                 starts_at: DateTime.utc_now()
               })
               |> Ash.create(authorize?: false, tenant: carrier.id)
    end
  end

  describe "scope shape" do
    test "a LOAD scope must name a load" do
      carrier = organization()
      person = user()
      subject = participant(carrier.id, person, carrier)
      definition = role_definition(carrier.id, "BROKER")

      assert {:error, error} =
               RoleAssignment
               |> Ash.Changeset.for_create(:grant, %{
                 tenant_id: carrier.id,
                 principal_type: :PARTICIPANT,
                 principal_id: subject.id,
                 organization_id: carrier.id,
                 role_definition_id: definition.id,
                 scope_type: :LOAD,
                 starts_at: DateTime.utc_now()
               })
               |> Ash.create(authorize?: false, tenant: carrier.id)

      assert Exception.message(error) =~ "required"
    end

    test "a SELF scope must not name a subject" do
      carrier = organization()
      person = user()
      subject = participant(carrier.id, person, carrier)
      definition = role_definition(carrier.id, "DRIVER")

      assert {:error, _error} =
               RoleAssignment
               |> Ash.Changeset.for_create(:grant, %{
                 tenant_id: carrier.id,
                 principal_type: :PARTICIPANT,
                 principal_id: subject.id,
                 organization_id: carrier.id,
                 role_definition_id: definition.id,
                 scope_type: :SELF,
                 scope_id: Ash.UUID.generate(),
                 starts_at: DateTime.utc_now()
               })
               |> Ash.create(authorize?: false, tenant: carrier.id)
    end
  end

  describe "device sequence monotonicity" do
    test "a replayed lower sequence is refused" do
      # Section 22.3 makes (device_id, device_sequence) the idempotency key for
      # status and location ingestion, so the counter must never go backwards.
      carrier = organization()
      person = user()
      subject = participant(carrier.id, person, carrier)

      device =
        Device
        |> Ash.Changeset.for_create(:register, %{
          tenant_id: carrier.id,
          participant_id: subject.id,
          installation_id: unique("install"),
          public_key: "key"
        })
        |> Ash.create!(authorize?: false, tenant: carrier.id)

      advanced =
        device
        |> Ash.Changeset.for_update(:record_sequence, %{last_sequence: 412})
        |> Ash.update!(authorize?: false, tenant: carrier.id)

      assert advanced.last_sequence == 412

      assert {:error, _replay} =
               advanced
               |> Ash.Changeset.for_update(:record_sequence, %{last_sequence: 411})
               |> Ash.update(authorize?: false, tenant: carrier.id)

      assert {:error, _same} =
               advanced
               |> Ash.Changeset.for_update(:record_sequence, %{last_sequence: 412})
               |> Ash.update(authorize?: false, tenant: carrier.id)
    end
  end
end
