defmodule Dispatch.FleetTest do
  @moduledoc """
  Loads, stops, party relationships, and assignments.

  The centre of this file is Section 22.2's rule that a `LOAD`- or `STOP`-scoped
  grant requires an active role assignment **and** a matching active party
  relationship. These use a real database because the rule lives partly in
  partial unique indexes and partly in time-bounded queries, and an in-memory
  double would agree with whatever the code did.
  """

  use ExUnit.Case, async: false

  alias Dispatch.Access
  alias Dispatch.Access.SeedManifest
  alias Dispatch.Accounts.{Organization, Participant, RoleAssignment, RoleDefinition, User}
  alias Dispatch.Fleet.{Assignment, Load, LoadParty, Stop, StopParty}
  alias Dispatch.Geo.Types.Point

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

  defp participant(tenant, org) do
    user =
      User
      |> Ash.Changeset.for_create(:register, %{
        oidc_subject: unique("sub"),
        display_name: "Operator"
      })
      |> Ash.create!(authorize?: false)

    Participant
    |> Ash.Changeset.for_create(:enroll, %{
      tenant_id: tenant,
      user_id: user.id,
      home_organization_id: org.id,
      public_name: "Operator"
    })
    |> Ash.create!(authorize?: false, tenant: tenant)
  end

  defp load(tenant, carrier, opts \\ []) do
    Load
    |> Ash.Changeset.for_create(
      :create_load,
      Enum.into(opts, %{tenant_id: tenant, carrier_organization_id: carrier.id})
    )
    |> Ash.create!(authorize?: false, tenant: tenant)
  end

  defp stop(tenant, load, kind, sequence, attrs \\ %{}) do
    Stop
    |> Ash.Changeset.for_create(
      :add,
      Map.merge(
        %{
          tenant_id: tenant,
          load_id: load.id,
          sequence: sequence,
          kind: kind,
          address_text: "#{kind} address"
        },
        attrs
      )
    )
    |> Ash.create!(authorize?: false, tenant: tenant)
  end

  defp role_definition(tenant, key, profile_module, capabilities) do
    RoleDefinition
    |> Ash.Changeset.for_create(:seed, %{
      tenant_id: tenant,
      key: key,
      label: key,
      capabilities_json: capabilities,
      profile_module: inspect(profile_module)
    })
    |> Ash.create!(authorize?: false, tenant: tenant)
  end

  defp grant(tenant, organization, subject, definition, scope_type, scope_id) do
    RoleAssignment
    |> Ash.Changeset.for_create(:grant, %{
      tenant_id: tenant,
      principal_type: :PARTICIPANT,
      principal_id: subject.id,
      organization_id: organization.id,
      role_definition_id: definition.id,
      scope_type: scope_type,
      scope_id: scope_id,
      starts_at: DateTime.add(DateTime.utc_now(), -3600, :second)
    })
    |> Ash.create!(authorize?: false, tenant: tenant)
    |> Ash.load!([:role_definition], authorize?: false, tenant: tenant)
  end

  defp plan_for(tenant, carrier, operator, role_grant) do
    attrs = %{
      tenant_id: tenant,
      load_id: load(tenant, carrier).id,
      operator_participant_id: operator.id,
      starts_at: DateTime.utc_now()
    }

    attrs =
      if role_grant, do: Map.put(attrs, :operator_role_assignment_id, role_grant.id), else: attrs

    Assignment
    |> Ash.Changeset.for_create(:plan, attrs)
    |> Ash.create!(authorize?: false, tenant: tenant)
  end

  defp activate(assignment, tenant) do
    assignment
    |> Ash.Changeset.for_update(:activate, %{})
    |> Ash.update(authorize?: false, tenant: tenant)
  end

  defp activate!(assignment, tenant) do
    {:ok, activated} = activate(assignment, tenant)
    activated
  end

  defp assignment_for(tenant, organization, key, scope_type, scope_id) do
    {:ok, manifest} = SeedManifest.fetch(key)

    definition =
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

    subject = participant(tenant, organization)

    RoleAssignment
    |> Ash.Changeset.for_create(:grant, %{
      tenant_id: tenant,
      principal_type: :PARTICIPANT,
      principal_id: subject.id,
      organization_id: organization.id,
      role_definition_id: definition.id,
      scope_type: scope_type,
      scope_id: scope_id,
      starts_at: DateTime.add(DateTime.utc_now(), -3600, :second)
    })
    |> Ash.create!(authorize?: false, tenant: tenant)
    |> Ash.load!([:role_definition], authorize?: false, tenant: tenant)
  end

  describe "Section 22.2: a role assignment alone is not enough" do
    setup do
      carrier = organization()
      broker_org = organization(:BROKER)
      tenant = carrier.id
      subject_load = load(tenant, carrier, broker_organization_id: broker_org.id)

      broker = assignment_for(tenant, broker_org, "BROKER", :LOAD, subject_load.id)

      %{
        tenant: tenant,
        carrier: carrier,
        broker_org: broker_org,
        load: subject_load,
        broker: broker
      }
    end

    test "a broker scoped to the load is still denied without a party relationship", ctx do
      # The assignment carries load.read and its scope names this exact load.
      assert Access.permits?(ctx.broker, "load.read", {:LOAD, ctx.load.id}, DateTime.utc_now())

      # Section 22.2 still denies: no active load_parties row exists.
      refute Access.Party.permits?(ctx.broker, "load.read", {:LOAD, ctx.load.id})
    end

    test "adding the party relationship grants access", ctx do
      LoadParty
      |> Ash.Changeset.for_create(:add, %{
        tenant_id: ctx.tenant,
        load_id: ctx.load.id,
        organization_id: ctx.broker_org.id,
        relationship: :BROKER,
        starts_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })
      |> Ash.create!(authorize?: false, tenant: ctx.tenant)

      assert Access.Party.permits?(ctx.broker, "load.read", {:LOAD, ctx.load.id})
    end

    test "ending the relationship revokes access immediately", ctx do
      # Acceptance criterion 15: removing the relationship terminates access at
      # once, not on the next sweep.
      party =
        LoadParty
        |> Ash.Changeset.for_create(:add, %{
          tenant_id: ctx.tenant,
          load_id: ctx.load.id,
          organization_id: ctx.broker_org.id,
          relationship: :BROKER,
          starts_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })
        |> Ash.create!(authorize?: false, tenant: ctx.tenant)

      assert Access.Party.permits?(ctx.broker, "load.read", {:LOAD, ctx.load.id})

      party
      |> Ash.Changeset.for_update(:end_relationship, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant)

      refute Access.Party.permits?(ctx.broker, "load.read", {:LOAD, ctx.load.id})
    end

    test "a party relationship on another load grants nothing here", ctx do
      other = load(ctx.tenant, ctx.carrier)

      LoadParty
      |> Ash.Changeset.for_create(:add, %{
        tenant_id: ctx.tenant,
        load_id: other.id,
        organization_id: ctx.broker_org.id,
        relationship: :BROKER,
        starts_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })
      |> Ash.create!(authorize?: false, tenant: ctx.tenant)

      refute Access.Party.permits?(ctx.broker, "load.read", {:LOAD, ctx.load.id})
    end

    test "a relationship of the wrong kind does not satisfy a narrowed check", ctx do
      # Being the shipper on a load does not make an organization its broker.
      LoadParty
      |> Ash.Changeset.for_create(:add, %{
        tenant_id: ctx.tenant,
        load_id: ctx.load.id,
        organization_id: ctx.broker_org.id,
        relationship: :SHIPPER,
        starts_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })
      |> Ash.create!(authorize?: false, tenant: ctx.tenant)

      refute Access.Party.permits?(ctx.broker, "load.read", {:LOAD, ctx.load.id},
               relationships: [:BROKER]
             )

      assert Access.Party.permits?(ctx.broker, "load.read", {:LOAD, ctx.load.id})
    end

    test "a future relationship does not grant access yet", ctx do
      LoadParty
      |> Ash.Changeset.for_create(:add, %{
        tenant_id: ctx.tenant,
        load_id: ctx.load.id,
        organization_id: ctx.broker_org.id,
        relationship: :BROKER,
        starts_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })
      |> Ash.create!(authorize?: false, tenant: ctx.tenant)

      refute Access.Party.permits?(ctx.broker, "load.read", {:LOAD, ctx.load.id})
    end
  end

  describe "Section 22.2: stop parties" do
    test "a shipper reaches its own pickup and not the delivery" do
      # Acceptance criteria 16 and 17: each counterparty sees its own stop.
      carrier = organization()
      shipper_org = organization(:SHIPPER)
      tenant = carrier.id
      subject_load = load(tenant, carrier)

      pickup = stop(tenant, subject_load, :PICKUP, 1)
      delivery = stop(tenant, subject_load, :DELIVERY, 2)

      shipper = assignment_for(tenant, shipper_org, "SHIPPER", :STOP, pickup.id)

      StopParty
      |> Ash.Changeset.for_create(:add, %{
        tenant_id: tenant,
        stop_id: pickup.id,
        organization_id: shipper_org.id,
        relationship: :SHIPPER,
        starts_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })
      |> Ash.create!(authorize?: false, tenant: tenant)

      assert Access.Party.permits?(shipper, "stop.update.readiness", {:STOP, pickup.id})
      refute Access.Party.permits?(shipper, "stop.update.readiness", {:STOP, delivery.id})
    end
  end

  describe "Section 22.2 constraints" do
    test "a duplicate overlapping active party relationship is refused" do
      carrier = organization()
      broker_org = organization(:BROKER)
      tenant = carrier.id
      subject_load = load(tenant, carrier)

      add = fn ->
        LoadParty
        |> Ash.Changeset.for_create(:add, %{
          tenant_id: tenant,
          load_id: subject_load.id,
          organization_id: broker_org.id,
          relationship: :BROKER,
          starts_at: DateTime.utc_now()
        })
        |> Ash.create(authorize?: false, tenant: tenant)
      end

      assert {:ok, party} = add.()
      assert {:error, _duplicate} = add.()

      party
      |> Ash.Changeset.for_update(:end_relationship, %{})
      |> Ash.update!(authorize?: false, tenant: tenant)

      # Ending frees the slot: the same organization may re-enter the role later.
      assert {:ok, _reinstated} = add.()
    end

    test "the DRIVER profile permits one ACTIVE assignment per operator" do
      carrier = organization()
      tenant = carrier.id
      operator = participant(tenant, carrier)

      driver_role =
        role_definition(tenant, "DRIVER", Dispatch.Access.Roles.Driver, ["status.declare.self"])

      driver_grant = grant(tenant, carrier, operator, driver_role, :SELF, nil)

      first = plan_for(tenant, carrier, operator, driver_grant)
      second = plan_for(tenant, carrier, operator, driver_grant)

      # Planning two is fine; running two is not. Section 6.1 scopes location
      # collection to the active assignment, so two would make a sample
      # unattributable.
      activated = activate!(first, tenant)

      assert {:error, _conflict} = activate(second, tenant)

      second
      |> Ash.Changeset.for_update(:cancel, %{})
      |> Ash.update!(authorize?: false, tenant: tenant)

      activated
      |> Ash.Changeset.for_update(:complete, %{})
      |> Ash.update!(authorize?: false, tenant: tenant)

      third = plan_for(tenant, carrier, operator, driver_grant)
      assert {:ok, _now_allowed} = activate(third, tenant)
    end

    test "a profile declaring concurrency is not bound by the index" do
      # Section 22.2 scopes the rule to DRIVER and lets other profiles declare a
      # different cardinality. A universal index would block work the
      # specification permits, which is the failure this test exists to catch.
      carrier = organization()
      tenant = carrier.id
      operator = participant(tenant, carrier)

      courier_role =
        role_definition(tenant, "COURIER", Dispatch.Support.Roles.Courier, ["status.declare.self"])

      courier_grant = grant(tenant, carrier, operator, courier_role, :SELF, nil)

      first = plan_for(tenant, carrier, operator, courier_grant)
      second = plan_for(tenant, carrier, operator, courier_grant)

      assert %{operator_exclusive: false} = first

      assert {:ok, _one} = activate(first, tenant)
      assert {:ok, _and_another} = activate(second, tenant)
    end

    test "an omitted role assignment keeps the restrictive default" do
      # The flag is derived, never asserted. A caller that says nothing — or
      # names a role assignment that cannot be resolved — gets the restriction,
      # because relaxing it on a lookup failure would be a fail-open.
      carrier = organization()
      tenant = carrier.id
      operator = participant(tenant, carrier)

      unnamed = plan_for(tenant, carrier, operator, nil)
      assert %{operator_exclusive: true} = unnamed

      unresolvable =
        Assignment
        |> Ash.Changeset.for_create(:plan, %{
          tenant_id: tenant,
          load_id: load(tenant, carrier).id,
          operator_participant_id: participant(tenant, carrier).id,
          starts_at: DateTime.utc_now(),
          operator_role_assignment_id: Ash.UUID.generate()
        })
        |> Ash.create!(authorize?: false, tenant: tenant)

      assert unresolvable.operator_exclusive
    end

    test "the flag cannot be set by the caller" do
      # Section 22.2 makes cardinality a matter of reviewed application policy,
      # so opting out must not be possible by asserting it does not apply.
      refute :operator_exclusive in Ash.Resource.Info.action(Assignment, :plan).accept
    end
  end

  describe "Section 19.2: money" do
    test "an amount without a currency is refused, and vice versa" do
      carrier = organization()
      tenant = carrier.id

      assert {:error, _no_currency} =
               Load
               |> Ash.Changeset.for_create(:create_load, %{
                 tenant_id: tenant,
                 carrier_organization_id: carrier.id,
                 agreed_rate_minor: 185_000
               })
               |> Ash.create(authorize?: false, tenant: tenant)

      assert {:error, _no_amount} =
               Load
               |> Ash.Changeset.for_create(:create_load, %{
                 tenant_id: tenant,
                 carrier_organization_id: carrier.id,
                 currency: "USD"
               })
               |> Ash.create(authorize?: false, tenant: tenant)

      assert {:ok, priced} =
               Load
               |> Ash.Changeset.for_create(:create_load, %{
                 tenant_id: tenant,
                 carrier_organization_id: carrier.id,
                 currency: "USD",
                 agreed_rate_minor: 185_000
               })
               |> Ash.create(authorize?: false, tenant: tenant)

      # Integer minor units, never a float (Section 19.2).
      assert is_integer(priced.agreed_rate_minor)
    end

    test "the negotiated rate is not a public field" do
      # Section 4.2 excludes negotiated rate from counterparty surfaces, and
      # Section 23.3 requires the field to stay hidden even where the record is
      # readable. A non-public attribute is not returned by a public read.
      public_fields = Ash.Resource.Info.public_attributes(Load) |> Enum.map(& &1.name)

      refute :agreed_rate_minor in public_fields
    end
  end

  describe "Section 28.2: PostGIS geometry" do
    test "a stop position round-trips as SRID 4326 in metres" do
      carrier = organization()
      tenant = carrier.id
      subject_load = load(tenant, carrier)

      placed =
        stop(tenant, subject_load, :PICKUP, 1, %{position: Point.from_lat_lng(37.7749, -122.4194)})

      assert %Geo.Point{srid: 4326, coordinates: {lng, lat}} = placed.position
      assert_in_delta lat, 37.7749, 0.000001
      assert_in_delta lng, -122.4194, 0.000001

      assert %{lat: ^lat, lng: ^lng} = Point.to_lat_lng(placed.position)
    end

    test "the column itself enforces Point and SRID 4326" do
      # Section 28.2 requires geography(Point,4326); a plain geometry column
      # would return distances in degrees and silently invalidate every
      # metre-based threshold in Sections 6.1, 25.3 and 28.3.
      %{rows: [[type, srid]]} =
        Ecto.Adapters.SQL.query!(
          Dispatch.Repo,
          "SELECT type, srid FROM geography_columns WHERE f_table_name = 'stops'",
          []
        )

      assert type == "Point"
      assert srid == 4326
    end
  end

  describe "stop windows" do
    test "a window that ends before it starts is refused" do
      carrier = organization()
      tenant = carrier.id
      subject_load = load(tenant, carrier)
      now = DateTime.utc_now()

      assert {:error, _inverted} =
               Stop
               |> Ash.Changeset.for_create(:add, %{
                 tenant_id: tenant,
                 load_id: subject_load.id,
                 sequence: 1,
                 kind: :PICKUP,
                 address_text: "Somewhere",
                 window_start: DateTime.add(now, 3600, :second),
                 window_end: now
               })
               |> Ash.create(authorize?: false, tenant: tenant)
    end
  end
end
