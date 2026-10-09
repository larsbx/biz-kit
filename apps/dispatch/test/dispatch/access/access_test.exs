defmodule Dispatch.AccessTest do
  @moduledoc """
  Capability resolution (Section 23.3).

  These build assignment and definition structs directly rather than going
  through the database, because the questions are about the decision function:
  what one assignment confers, at what instant, over what scope. The
  database-backed policy behaviour is covered separately.
  """

  use ExUnit.Case, async: true

  alias Dispatch.Access
  alias Dispatch.Access.SeedManifest
  alias Dispatch.Accounts.{RoleAssignment, RoleDefinition}

  @now ~U[2026-09-18 12:00:00.000000Z]
  @tenant "01a0b48d-0000-7000-8000-000000000001"

  defp definition(key) do
    {:ok, manifest} = SeedManifest.fetch(key)

    %RoleDefinition{
      id: "01a0b48d-0000-7000-8000-00000000000#{:erlang.phash2(key, 9)}",
      tenant_id: @tenant,
      key: manifest.key,
      label: manifest.label,
      capabilities_json: manifest.capabilities,
      constraints_json: manifest.constraints,
      profile_module: inspect(manifest.profile_module),
      status: :ACTIVE
    }
  end

  defp assignment(key, overrides \\ %{}) do
    base = %RoleAssignment{
      id: "01a0b48d-0000-7000-8000-0000000000a1",
      tenant_id: @tenant,
      principal_type: :PARTICIPANT,
      principal_id: "01a0b48d-0000-7000-8000-0000000000b1",
      organization_id: "01a0b48d-0000-7000-8000-0000000000c1",
      role_definition_id: definition(key).id,
      role_definition: definition(key),
      scope_type: :SELF,
      scope_id: nil,
      starts_at: ~U[2026-09-01 00:00:00.000000Z],
      ends_at: nil,
      status: :ACTIVE
    }

    struct!(base, overrides)
  end

  describe "validity in time" do
    test "an assignment inside its window is in force" do
      assert Access.active_at?(assignment("DRIVER"), @now)
    end

    test "an assignment that has not started is not in force" do
      future = assignment("DRIVER", %{starts_at: ~U[2026-10-01 00:00:00.000000Z]})

      refute Access.active_at?(future, @now)
      assert Access.capabilities(future, @now) == []
    end

    test "an ended assignment is not in force" do
      ended = assignment("DRIVER", %{ends_at: ~U[2026-09-17 00:00:00.000000Z]})

      refute Access.active_at?(ended, @now)
    end

    test "ends_at is exclusive at the boundary" do
      # Section 23.3 requires an expired assignment to fail closed; a boundary
      # that included the end instant would leave a one-microsecond grant.
      boundary = assignment("DRIVER", %{ends_at: @now})

      refute Access.active_at?(boundary, @now)
      assert Access.active_at?(%{boundary | ends_at: DateTime.add(@now, 1, :microsecond)}, @now)
    end

    test "starts_at is inclusive at the boundary" do
      assert Access.active_at?(assignment("DRIVER", %{starts_at: @now}), @now)
    end

    test "a revoked assignment confers nothing even inside its window" do
      revoked = assignment("DRIVER", %{status: :REVOKED})

      refute Access.active_at?(revoked, @now)
      assert Access.capabilities(revoked, @now) == []
      refute Access.can?(revoked, "status.declare.self", @now)
    end
  end

  describe "capability resolution" do
    test "a driver assignment confers the seeded driver bundle" do
      {:ok, manifest} = SeedManifest.fetch("DRIVER")

      assert Access.capabilities(assignment("DRIVER"), @now) == Enum.sort(manifest.capabilities)
    end

    test "an unloaded role definition confers nothing" do
      # A forgotten `load` must read as no authority, not as unchecked
      # authority. This is the difference between failing closed and failing
      # open on a coding mistake.
      unloaded = assignment("DRIVER", %{role_definition: nil})

      assert Access.capabilities(unloaded, @now) == []
      refute Access.can?(unloaded, "status.declare.self", @now)
    end

    test "a definition naming a non-allowlisted module confers nothing" do
      # Section 31 fails startup in this state; this is the runtime floor
      # beneath it, so a row written before an allowlist narrowed grants nothing.
      rogue = assignment("DRIVER")

      rogue = %{
        rogue
        | role_definition: %{rogue.role_definition | profile_module: "Elixir.Kernel"}
      }

      assert Access.capabilities(rogue, @now) == []
    end

    test "an admin assignment confers no operational read" do
      admin = assignment("ADMIN", %{scope_type: :ORGANIZATION})

      assert Access.can?(admin, "role_assignment.manage", @now)
      refute Access.can?(admin, "operations.participant.read", @now)
      refute Access.can?(admin, "operations.location.precise.read", @now)
      refute Access.can?(admin, "load.read", @now)
    end
  end

  describe "scope" do
    test "SELF and ORGANIZATION scopes are bounded by the organization, not a subject id" do
      assert Access.in_scope?(
               assignment("DRIVER", %{scope_type: :SELF}),
               {:LOAD, Ash.UUID.generate()}
             )

      assert Access.in_scope?(
               assignment("DISPATCHER", %{scope_type: :ORGANIZATION}),
               {:STOP, Ash.UUID.generate()}
             )
    end

    test "a LOAD scope matches only its own load" do
      load_id = Ash.UUID.generate()
      broker = assignment("BROKER", %{scope_type: :LOAD, scope_id: load_id})

      assert Access.in_scope?(broker, {:LOAD, load_id})
      refute Access.in_scope?(broker, {:LOAD, Ash.UUID.generate()})
      refute Access.in_scope?(broker, {:STOP, load_id})
    end

    test "a STOP scope matches only its own stop" do
      stop_id = Ash.UUID.generate()
      shipper = assignment("SHIPPER", %{scope_type: :STOP, scope_id: stop_id})

      assert Access.in_scope?(shipper, {:STOP, stop_id})
      refute Access.in_scope?(shipper, {:STOP, Ash.UUID.generate()})
    end

    test "permits? requires capability and scope together" do
      stop_id = Ash.UUID.generate()
      shipper = assignment("SHIPPER", %{scope_type: :STOP, scope_id: stop_id})

      assert Access.permits?(shipper, "stop.update.readiness", {:STOP, stop_id}, @now)

      # Right capability, wrong stop.
      refute Access.permits?(shipper, "stop.update.readiness", {:STOP, Ash.UUID.generate()}, @now)

      # Right stop, capability the profile does not carry.
      refute Access.permits?(shipper, "load.update.nonbinding", {:STOP, stop_id}, @now)
    end
  end

  describe "Section 23.3: capabilities never union across assignments" do
    test "the module exposes no function that takes several assignments" do
      # The rule is enforced by absence. If a plural arity appears here, someone
      # has added the convenience that Section 23.3 forbids, and every caller
      # would then be one refactor away from combining a driver's self-service
      # capabilities with an admin's management ones.
      plural =
        Dispatch.Access.__info__(:functions)
        |> Enum.filter(fn {name, _arity} ->
          name |> Atom.to_string() |> String.ends_with?("_for_assignments")
        end)

      assert plural == []
    end

    test "each assignment resolves independently" do
      driver = assignment("DRIVER")
      admin = assignment("ADMIN", %{scope_type: :ORGANIZATION})

      assert Access.can?(driver, "status.declare.self", @now)
      refute Access.can?(admin, "status.declare.self", @now)

      assert Access.can?(admin, "membership.manage", @now)
      refute Access.can?(driver, "membership.manage", @now)
    end
  end

  describe "Android feature derivation" do
    test "features come from the profile module, not a role key" do
      # Section 23.2: Android features are enabled from a signed server
      # capability document, never from `if role == DRIVER`.
      features = Access.android_features(assignment("DRIVER"), @now)

      assert "status" in features
      assert "approvals" in features
    end

    test "a role with no field application declares no features" do
      assert Access.android_features(assignment("ADMIN", %{scope_type: :ORGANIZATION}), @now) ==
               []
    end

    test "an expired assignment declares no features" do
      expired = assignment("DRIVER", %{ends_at: ~U[2026-09-17 00:00:00.000000Z]})

      assert Access.android_features(expired, @now) == []
    end
  end

  describe "operations projection" do
    test "each profile renders its Section 4.3 surface" do
      assert Access.operations_projection(assignment("DRIVER")) == :participant

      assert Access.operations_projection(assignment("ADMIN", %{scope_type: :ORGANIZATION})) ==
               :settings

      assert Access.operations_projection(assignment("DISPATCHER", %{scope_type: :ORGANIZATION})) ==
               :operations

      assert Access.operations_projection(
               assignment("BROKER", %{scope_type: :LOAD, scope_id: Ash.UUID.generate()})
             ) == :load
    end
  end
end
