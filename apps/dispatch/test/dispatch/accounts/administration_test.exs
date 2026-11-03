defmodule Dispatch.Accounts.AdministrationTest do
  @moduledoc "Section 23.3's rules for administrative role management."

  use ExUnit.Case, async: false

  require Ash.Query

  alias Dispatch.Access.Actor
  alias Dispatch.Accounts.{Administration, RoleAssignment}
  alias Dispatch.Audit.AuditEvent
  alias Dispatch.Fleet.{Trailer, Vehicle}
  alias Dispatch.Support.Fixtures

  @moduletag :integration

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)

    carrier = Fixtures.carrier()
    tenant = carrier.id

    definitions =
      Map.new(~w(ADMIN DISPATCHER DRIVER SHIPPER), &{&1, Fixtures.role_definition(tenant, &1)})

    %{participant: admin} = Fixtures.person(tenant, carrier, display_name: "Admin")
    %{participant: driver} = Fixtures.person(tenant, carrier, display_name: "Driver")

    admin_assignment =
      Fixtures.assignment(tenant, carrier, admin, "ADMIN", definition: definitions["ADMIN"])

    {:ok, actor} = Actor.from_assignment(admin_assignment)

    %{
      tenant: tenant,
      carrier: carrier,
      definitions: definitions,
      admin: admin,
      driver: driver,
      actor: actor,
      admin_assignment: admin_assignment,
      now: DateTime.utc_now()
    }
  end

  defp grant(ctx, participant, key, opts \\ []) do
    Administration.grant(
      Keyword.get(ctx_actor(ctx, opts), :actor),
      %{"participant_id" => participant.id, "role_definition_id" => ctx.definitions[key].id},
      Keyword.get(opts, :authenticated_at, ctx.now)
    )
  end

  defp ctx_actor(ctx, opts), do: [actor: Keyword.get(opts, :actor, ctx.actor)]

  defp minutes_ago(ctx, minutes), do: DateTime.add(ctx.now, -minutes * 60, :second)

  describe "who may manage" do
    test "an assignment without role_assignment.manage sees and changes nothing", ctx do
      dispatcher =
        Fixtures.actor(ctx.tenant, ctx.carrier, ctx.driver, "DISPATCHER",
          definition: ctx.definitions["DISPATCHER"]
        )

      assert Administration.overview(dispatcher) == {:error, :not_found}
      assert grant(ctx, ctx.admin, "DRIVER", actor: dispatcher) == {:error, :not_found}
    end

    test "the overview lists the organization's people and the grantable roles", ctx do
      {:ok, %{members: members, grantable: grantable}} = Administration.overview(ctx.actor)

      assert Enum.map(members, & &1.participant.public_name) == ["Admin", "Driver"]
      assert [%{id: id}] = Enum.find(members, &(&1.participant.id == ctx.admin.id)).assignments
      assert id == ctx.admin_assignment.id

      # A STOP-scoped profile needs its stop's party row; it is granted with the stop.
      assert Enum.map(grantable, & &1.key) |> Enum.sort() == ~w(ADMIN DISPATCHER DRIVER)
    end
  end

  describe "granting" do
    test "a recent sign-in grants, and the grant is audited", ctx do
      assert {:ok, %RoleAssignment{} = granted} = grant(ctx, ctx.driver, "DRIVER")
      assert granted.principal_id == ctx.driver.id
      assert granted.scope_type == :SELF

      [audit] =
        AuditEvent
        |> Ash.Query.filter(event_type == "role_assignment.granted")
        |> Ash.read!(authorize?: false, tenant: ctx.tenant)

      assert audit.actor_id == ctx.admin.id
      assert audit.role_assignment_id == ctx.admin_assignment.id
      assert audit.subject_id == ctx.driver.id
      assert audit.payload_json["role"] == "DRIVER"
    end

    test "a step-up is a sign-in within five minutes, not an old session", ctx do
      assert {:ok, _} = grant(ctx, ctx.driver, "DRIVER", authenticated_at: minutes_ago(ctx, 4))

      assert grant(ctx, ctx.driver, "DISPATCHER", authenticated_at: minutes_ago(ctx, 6)) ==
               {:error, :step_up_required}

      assert grant(ctx, ctx.driver, "DISPATCHER", authenticated_at: nil) ==
               {:error, :step_up_required}
    end

    test "an administrator cannot grant themselves anything", ctx do
      assert grant(ctx, ctx.admin, "DISPATCHER") == {:error, :own_assignment}
      assert grant(ctx, ctx.admin, "ADMIN") == {:error, :own_assignment}
    end

    test "someone outside the organization, or a role outside the catalogue, is not found", ctx do
      elsewhere = Fixtures.carrier()
      %{participant: stranger} = Fixtures.person(ctx.tenant, elsewhere)

      assert grant(ctx, stranger, "DRIVER") == {:error, :not_found}

      suspended =
        ctx.driver
        |> Ash.Changeset.for_update(:set_status, %{status: :SUSPENDED})
        |> Ash.update!(authorize?: false, tenant: ctx.tenant)

      assert grant(ctx, suspended, "DRIVER") == {:error, :not_found}
      assert grant(ctx, ctx.driver, "SHIPPER") == {:error, :not_found}

      assert Administration.grant(ctx.actor, %{"participant_id" => "nope"}, ctx.now) ==
               {:error, :not_found}
    end

    test "the same role twice is refused, not duplicated", ctx do
      assert {:ok, _} = grant(ctx, ctx.driver, "DRIVER")
      assert grant(ctx, ctx.driver, "DRIVER") == {:error, :already_granted}
    end
  end

  describe "revoking" do
    test "ends the assignment at the version the administrator saw", ctx do
      {:ok, granted} = grant(ctx, ctx.driver, "DISPATCHER")

      assert Administration.revoke(ctx.actor, granted.id, granted.version + 1, ctx.now) ==
               {:error, :stale}

      assert {:ok, %RoleAssignment{status: :REVOKED}} =
               Administration.revoke(ctx.actor, granted.id, granted.version, ctx.now)

      # Gone from what the administrator can act on.
      assert Administration.revoke(ctx.actor, granted.id, granted.version + 1, ctx.now) ==
               {:error, :not_found}
    end

    test "without the version the page showed, nothing is revoked", ctx do
      {:ok, granted} = grant(ctx, ctx.driver, "DISPATCHER")

      assert Administration.revoke(ctx.actor, granted.id, nil, ctx.now) == {:error, :stale}
    end

    test "needs a recent sign-in too", ctx do
      {:ok, granted} = grant(ctx, ctx.driver, "DRIVER")

      assert Administration.revoke(ctx.actor, granted.id, granted.version, minutes_ago(ctx, 6)) ==
               {:error, :step_up_required}
    end

    test "the organization's last administrator stays", ctx do
      own = ctx.admin_assignment

      assert Administration.revoke(ctx.actor, own.id, own.version, ctx.now) ==
               {:error, :last_administrator}

      {:ok, _second} = grant(ctx, ctx.driver, "ADMIN")

      assert {:ok, _} = Administration.revoke(ctx.actor, own.id, own.version, ctx.now)
    end

    test "an administrator who can no longer sign in does not count as another", ctx do
      own = ctx.admin_assignment
      {:ok, _second} = grant(ctx, ctx.driver, "ADMIN")

      ctx.driver
      |> Ash.Changeset.for_update(:set_status, %{status: :SUSPENDED})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant)

      assert Administration.revoke(ctx.actor, own.id, own.version, ctx.now) ==
               {:error, :last_administrator}
    end

    test "nor does one whose user is no longer active", ctx do
      own = ctx.admin_assignment
      %{user: user, participant: other} = Fixtures.person(ctx.tenant, ctx.carrier)
      {:ok, _second} = grant(ctx, other, "ADMIN")

      user
      |> Ash.Changeset.for_update(:set_status, %{status: :CLOSED})
      |> Ash.update!(authorize?: false)

      assert Administration.revoke(ctx.actor, own.id, own.version, ctx.now) ==
               {:error, :last_administrator}
    end
  end

  # Owner rule (2026-11-02): a driver's role ends only once their equipment is
  # checked in, i.e. no active trip of theirs in the organization holds a vehicle
  # or trailer.
  describe "a driver's equipment" do
    setup ctx do
      role =
        Fixtures.assignment(ctx.tenant, ctx.carrier, ctx.driver, "DRIVER",
          definition: ctx.definitions["DRIVER"]
        )

      %{driver_role: role}
    end

    defp trip(ctx, status, equipment) do
      opts =
        Enum.map(equipment, fn
          Vehicle -> {:vehicle_id, Fixtures.equipment(ctx.tenant, ctx.carrier, Vehicle).id}
          Trailer -> {:trailer_id, Fixtures.equipment(ctx.tenant, ctx.carrier, Trailer).id}
        end)

      planned = Fixtures.assignment_record(ctx.tenant, ctx.carrier, ctx.driver, opts)

      Enum.reduce(status, planned, fn action, trip ->
        trip
        |> Ash.Changeset.for_update(action, %{})
        |> Ash.update!(authorize?: false, tenant: ctx.tenant)
      end)
    end

    defp revoke_driver(ctx),
      do: Administration.revoke(ctx.actor, ctx.driver_role.id, ctx.driver_role.version, ctx.now)

    for equipment <- [[Vehicle], [Trailer], [Vehicle, Trailer]] do
      @equipment equipment
      test "is refused while an active trip holds #{inspect(equipment)}", ctx do
        trip(ctx, [:activate], @equipment)

        assert revoke_driver(ctx) == {:error, :equipment_not_checked_in}
        assert active?(ctx, ctx.driver_role)
      end
    end

    test "is allowed once that trip completes", ctx do
      trip(ctx, [:activate, :complete], [Vehicle])
      assert {:ok, %RoleAssignment{status: :REVOKED}} = revoke_driver(ctx)
    end

    test "is allowed when the active trip holds no equipment, or a planned one does", ctx do
      trip(ctx, [:activate], [])
      trip(ctx, [], [Vehicle, Trailer])
      assert {:ok, %RoleAssignment{status: :REVOKED}} = revoke_driver(ctx)
    end

    test "is allowed while another driving role of theirs stays in force", ctx do
      trip(ctx, [:activate], [Vehicle])
      {:ok, manifest} = Dispatch.Access.SeedManifest.fetch("DRIVER")

      relief =
        Dispatch.Accounts.RoleDefinition
        |> Ash.Changeset.for_create(:seed, %{
          tenant_id: ctx.tenant,
          key: "RELIEF_DRIVER",
          label: "Relief driver",
          capabilities_json: manifest.capabilities,
          constraints_json: manifest.constraints,
          profile_module: inspect(manifest.profile_module)
        })
        |> Ash.create!(authorize?: false, tenant: ctx.tenant)

      _other =
        Fixtures.assignment(ctx.tenant, ctx.carrier, ctx.driver, "DRIVER", definition: relief)

      assert {:ok, %RoleAssignment{status: :REVOKED}} = revoke_driver(ctx)
    end

    test "does not hold back a role that does not drive", ctx do
      trip(ctx, [:activate], [Vehicle])
      {:ok, desk} = grant(ctx, ctx.driver, "DISPATCHER")

      assert {:ok, %RoleAssignment{status: :REVOKED}} =
               Administration.revoke(ctx.actor, desk.id, desk.version, ctx.now)
    end

    defp active?(ctx, assignment) do
      Ash.get!(RoleAssignment, assignment.id, authorize?: false, tenant: ctx.tenant).status ==
        :ACTIVE
    end
  end
end
