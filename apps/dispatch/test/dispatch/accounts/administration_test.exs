defmodule Dispatch.Accounts.AdministrationTest do
  @moduledoc "Section 23.3's rules for administrative role management."

  use ExUnit.Case, async: false

  require Ash.Query

  alias Dispatch.Access.Actor
  alias Dispatch.Accounts.{Administration, RoleAssignment}
  alias Dispatch.Audit.AuditEvent
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
      assert Administration.revoke(ctx.actor, granted.id, nil, ctx.now) == {:error, :not_found}
    end

    test "needs a recent sign-in too", ctx do
      {:ok, granted} = grant(ctx, ctx.driver, "DRIVER")

      assert Administration.revoke(ctx.actor, granted.id, nil, minutes_ago(ctx, 6)) ==
               {:error, :step_up_required}
    end

    test "the organization's last administrator stays", ctx do
      assert Administration.revoke(ctx.actor, ctx.admin_assignment.id, nil, ctx.now) ==
               {:error, :last_administrator}

      {:ok, _second} = grant(ctx, ctx.driver, "ADMIN")

      assert {:ok, _} = Administration.revoke(ctx.actor, ctx.admin_assignment.id, nil, ctx.now)
    end
  end
end
