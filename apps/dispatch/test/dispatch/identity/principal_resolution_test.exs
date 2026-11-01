defmodule Dispatch.Identity.PrincipalResolutionTest do
  @moduledoc """
  Section 24.6's "selects authority context but never grants it", at the level
  the HTTP tests cannot reach.

  The case that shapes this module is a user holding assignments in more than
  one operating organization. Users are global and tenants are not (ADR-0005),
  so resolution is the one read that must span tenants — and everything after it
  must be firmly inside one.
  """

  use ExUnit.Case, async: false

  alias Dispatch.Identity.PrincipalResolution
  alias Dispatch.Support.Fixtures

  @moduletag :integration

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)

    org = Fixtures.carrier()
    %{user: user, participant: driver} = Fixtures.person(org.id, org)
    assignment = Fixtures.assignment(org.id, org, driver, "DRIVER")

    %{org: org, tenant: org.id, user: user, driver: driver, assignment: assignment}
  end

  describe "a single active assignment" do
    test "resolves without a header and carries its own tenant", ctx do
      assert {:ok, actor} = PrincipalResolution.actor(ctx.user.oidc_subject)

      assert actor.principal_id == ctx.driver.id
      assert actor.tenant_id == ctx.tenant
      assert actor.role_assignment.id == ctx.assignment.id
      # `Dispatch.Access` treats an unloaded definition as conferring nothing,
      # so an actor built without one would silently carry no capabilities.
      assert actor.role_assignment.role_definition.key == "DRIVER"
    end

    test "an unknown subject resolves to nothing" do
      assert {:error, :unknown_principal} = PrincipalResolution.actor("no-such-subject")
    end
  end

  describe "assignments in more than one tenant" do
    setup ctx do
      other_org = Fixtures.carrier()

      # The same global user, enrolled as a second participant elsewhere.
      %{participant: elsewhere} = Fixtures.person(other_org.id, other_org, user: ctx.user)

      second = Fixtures.assignment(other_org.id, other_org, elsewhere, "DISPATCHER")

      %{other_org: other_org, elsewhere: elsewhere, second: second}
    end

    test "are ambiguous without a header", ctx do
      # Section 23.3 forbids unioning capabilities across assignments. Choosing
      # one on the caller's behalf would be a union by another name.
      assert {:error, :ambiguous_role_assignment} =
               PrincipalResolution.actor(ctx.user.oidc_subject)
    end

    test "the header selects one, and its tenant comes with it", ctx do
      assert {:ok, actor} = PrincipalResolution.actor(ctx.user.oidc_subject, ctx.second.id)

      assert actor.tenant_id == ctx.other_org.id
      assert actor.principal_id == ctx.elsewhere.id
      assert actor.role_assignment.role_definition.key == "DISPATCHER"

      assert {:ok, first} = PrincipalResolution.actor(ctx.user.oidc_subject, ctx.assignment.id)
      assert first.tenant_id == ctx.tenant
    end

    test "selectable roles identify the organization that owns each assignment", ctx do
      options = PrincipalResolution.selectable(ctx.user.oidc_subject)

      assert Enum.find(options, &(&1.id == ctx.assignment.id)) == %{
               id: ctx.assignment.id,
               label: "#{ctx.org.name} — #{ctx.assignment.role_definition.label}"
             }

      assert Enum.find(options, &(&1.id == ctx.second.id)) == %{
               id: ctx.second.id,
               label: "#{ctx.other_org.name} — #{ctx.second.role_definition.label}"
             }
    end

    test "identical role names in two organizations remain distinguishable", ctx do
      other_driver = Fixtures.assignment(ctx.other_org.id, ctx.other_org, ctx.elsewhere, "DRIVER")
      options = PrincipalResolution.selectable(ctx.user.oidc_subject)

      assert Enum.find(options, &(&1.id == ctx.assignment.id)).label ==
               "#{ctx.org.name} — #{ctx.assignment.role_definition.label}"

      assert Enum.find(options, &(&1.id == other_driver.id)).label ==
               "#{ctx.other_org.name} — #{other_driver.role_definition.label}"

      refute ctx.org.name == ctx.other_org.name
    end

    test "a suspended organization cannot be selected alongside an active one", ctx do
      ctx.other_org
      |> Ash.Changeset.for_update(:set_status, %{status: :SUSPENDED})
      |> Ash.update!(authorize?: false)

      assert {:ok, actor} = PrincipalResolution.actor(ctx.user.oidc_subject)
      assert actor.role_assignment.id == ctx.assignment.id
      assert {:error, :role_assignment_not_held} =
               PrincipalResolution.actor(ctx.user.oidc_subject, ctx.second.id)
      assert Enum.map(PrincipalResolution.selectable(ctx.user.oidc_subject), & &1.id) ==
               [ctx.assignment.id]
    end

    test "a header naming an assignment held by someone else selects nothing", ctx do
      stranger_org = Fixtures.carrier()
      %{participant: stranger} = Fixtures.person(stranger_org.id, stranger_org)
      theirs = Fixtures.assignment(stranger_org.id, stranger_org, stranger, "DRIVER")

      assert {:error, :role_assignment_not_held} =
               PrincipalResolution.actor(ctx.user.oidc_subject, theirs.id)
    end
  end

  describe "validity is re-read, never trusted" do
    test "a revoked assignment stops resolving", ctx do
      ctx.assignment
      |> Ash.Changeset.for_update(:revoke, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant)

      assert {:error, :no_active_assignment} = PrincipalResolution.actor(ctx.user.oidc_subject)
    end

    test "an assignment whose window has closed stops resolving", ctx do
      %{user: user, participant: person} = Fixtures.person(ctx.tenant, ctx.org)

      Fixtures.assignment(ctx.tenant, ctx.org, person, "DRIVER",
        starts_at: DateTime.add(DateTime.utc_now(), -7200, :second),
        ends_at: DateTime.add(DateTime.utc_now(), -60, :second)
      )

      assert {:error, :no_active_assignment} = PrincipalResolution.actor(user.oidc_subject)
    end

    test "a fabricated held actor cannot adopt another participant's assignment", ctx do
      assert {:ok, genuine} = PrincipalResolution.actor(ctx.user.oidc_subject)
      %{participant: another} = Fixtures.person(ctx.tenant, ctx.org)

      forged = %{genuine | principal_id: another.id}

      assert {:error, :role_assignment_not_active} =
               PrincipalResolution.revalidate(forged)
      assert {:ok, original} = PrincipalResolution.revalidate(genuine)
      assert original.principal_id == ctx.driver.id
    end

    test "suspended participant invalidates a held actor before a stream or job can use it", ctx do
      assert {:ok, held_actor} = PrincipalResolution.actor(ctx.user.oidc_subject)

      ctx.driver
      |> Ash.Changeset.for_update(:set_status, %{status: :SUSPENDED})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant)

      assert {:error, :role_assignment_not_active} =
               PrincipalResolution.revalidate(held_actor)
      assert {:error, :no_active_assignment} = PrincipalResolution.actor(ctx.user.oidc_subject)
    end

    test "closed global user invalidates a held actor", ctx do
      assert {:ok, held_actor} = PrincipalResolution.actor(ctx.user.oidc_subject)

      ctx.user
      |> Ash.Changeset.for_update(:set_status, %{status: :CLOSED})
      |> Ash.update!(authorize?: false)

      assert {:error, :role_assignment_not_active} =
               PrincipalResolution.revalidate(held_actor)
      assert {:error, :unknown_principal} = PrincipalResolution.actor(ctx.user.oidc_subject)
    end

    test "suspension revokes organizational access including held-actor revalidation", ctx do
      assert {:ok, held_actor} = PrincipalResolution.actor(ctx.user.oidc_subject)

      ctx.org
      |> Ash.Changeset.for_update(:set_status, %{status: :SUSPENDED})
      |> Ash.update!(authorize?: false)

      assert PrincipalResolution.selectable(ctx.user.oidc_subject) == []
      assert {:error, :no_active_assignment} = PrincipalResolution.actor(ctx.user.oidc_subject)
      assert {:error, :role_assignment_not_active} =
               PrincipalResolution.revalidate(held_actor)
    end

    test "an assignment whose window has not opened does not resolve yet", ctx do
      %{user: user, participant: person} = Fixtures.person(ctx.tenant, ctx.org)

      Fixtures.assignment(ctx.tenant, ctx.org, person, "DRIVER",
        starts_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      )

      assert {:error, :no_active_assignment} = PrincipalResolution.actor(user.oidc_subject)
    end
  end
end
