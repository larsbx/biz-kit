defmodule Dispatch.OperationsTest do
  @moduledoc """
  Status declarations and the audit chain.

  Section 1's central distinction is what most of this protects: a status is a
  *driver declaration*, not an observed fact or an inference, and Section 5.2
  permits only the participant themselves to make one. The deny tests matter
  more than the allow tests — Section 35 requires every new authorization path
  to have one, and a policy that has never been seen to refuse is not known to
  work.
  """

  use ExUnit.Case, async: false

  alias Dispatch.Access.Actor
  alias Dispatch.Access.SeedManifest
  alias Dispatch.Accounts.{Organization, Participant, RoleAssignment, RoleDefinition, User}
  alias Dispatch.Audit.AuditEvent
  alias Dispatch.Operations.ParticipantStatusEvent

  require Ash.Query

  @moduletag :integration

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp carrier do
    Organization
    |> Ash.Changeset.for_create(:register, %{name: unique("Carrier"), kind: :CARRIER})
    |> Ash.create!(authorize?: false)
  end

  defp participant(tenant, org) do
    user =
      User
      |> Ash.Changeset.for_create(:register, %{
        oidc_subject: unique("sub"),
        display_name: "Person"
      })
      |> Ash.create!(authorize?: false)

    Participant
    |> Ash.Changeset.for_create(:enroll, %{
      tenant_id: tenant,
      user_id: user.id,
      home_organization_id: org.id,
      public_name: "Person"
    })
    |> Ash.create!(authorize?: false, tenant: tenant)
  end

  defp actor_for(tenant, org, subject, key) do
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

    assignment =
      RoleAssignment
      |> Ash.Changeset.for_create(:grant, %{
        tenant_id: tenant,
        principal_type: :PARTICIPANT,
        principal_id: subject.id,
        organization_id: org.id,
        role_definition_id: definition.id,
        scope_type: if(key == "DRIVER", do: :SELF, else: :ORGANIZATION),
        starts_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      })
      |> Ash.create!(authorize?: false, tenant: tenant)
      |> Ash.load!([:role_definition], authorize?: false, tenant: tenant)

    {:ok, actor} = Actor.from_assignment(assignment)
    actor
  end

  defp declare(actor, subject, attrs) do
    ParticipantStatusEvent
    |> Ash.Changeset.for_create(
      :declare,
      Map.merge(
        %{
          tenant_id: actor.tenant_id,
          participant_id: subject.id,
          role_assignment_id: actor.role_assignment.id,
          occurred_at: DateTime.utc_now()
        },
        attrs
      )
    )
    |> Ash.create(actor: actor, tenant: actor.tenant_id)
  end

  describe "Section 5.2: only the participant declares their own status" do
    setup do
      org = carrier()
      tenant = org.id
      driver = participant(tenant, org)
      %{org: org, tenant: tenant, driver: driver, actor: actor_for(tenant, org, driver, "DRIVER")}
    end

    test "a driver declares their own status", ctx do
      assert {:ok, event} = declare(ctx.actor, ctx.driver, %{status: :EN_ROUTE_PICKUP})

      assert event.status == :EN_ROUTE_PICKUP
      assert event.source == :PARTICIPANT
      # Section 4.2 shows declaration time and age; the two instants stay apart.
      assert event.recorded_at
      assert event.occurred_at
    end

    test "a driver cannot declare a status about someone else", ctx do
      other = participant(ctx.tenant, ctx.org)

      assert {:error, %Ash.Error.Forbidden{}} =
               declare(ctx.actor, other, %{status: :AT_PICKUP})
    end

    test "a dispatcher cannot declare a status at all", ctx do
      # Section 23.2 gives a dispatcher no self-service capability. An inference
      # or an operator note is not a declaration (Section 1).
      dispatcher = participant(ctx.tenant, ctx.org)
      dispatcher_actor = actor_for(ctx.tenant, ctx.org, dispatcher, "DISPATCHER")

      assert {:error, %Ash.Error.Forbidden{}} =
               declare(dispatcher_actor, dispatcher, %{status: :AT_PICKUP})
    end

    test "a revoked role assignment declares nothing", ctx do
      # Section 23.3 requires a revoked assignment to fail closed everywhere at
      # once. An assignment with no `ends_at` is open-ended by design, so the
      # revocation — not the passage of time — is what must deny.
      ctx.actor.role_assignment
      |> Ash.Changeset.for_update(:revoke, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant)

      reloaded =
        RoleAssignment
        |> Ash.get!(ctx.actor.role_assignment.id, authorize?: false, tenant: ctx.tenant)
        |> Ash.load!([:role_definition], authorize?: false, tenant: ctx.tenant)

      revoked = %{ctx.actor | role_assignment: reloaded}

      assert {:error, %Ash.Error.Forbidden{}} =
               declare(revoked, ctx.driver, %{status: :AT_PICKUP})
    end

    test "an assignment whose window has closed declares nothing", ctx do
      ended =
        %{
          ctx.actor
          | role_assignment: %{
              ctx.actor.role_assignment
              | ends_at: DateTime.add(DateTime.utc_now(), -60, :second)
            }
        }

      assert {:error, %Ash.Error.Forbidden{}} =
               declare(ended, ctx.driver, %{status: :AT_PICKUP})
    end
  end

  describe "Section 24.1 validation" do
    setup do
      org = carrier()
      tenant = org.id
      driver = participant(tenant, org)
      %{tenant: tenant, driver: driver, actor: actor_for(tenant, org, driver, "DRIVER")}
    end

    test "DELAYED and BREAKDOWN require a note", ctx do
      for status <- [:DELAYED, :BREAKDOWN] do
        assert {:error, _blank} = declare(ctx.actor, ctx.driver, %{status: status})

        assert {:error, _whitespace} =
                 declare(ctx.actor, ctx.driver, %{status: status, note: "   "})

        assert {:ok, _with_reason} =
                 declare(ctx.actor, ctx.driver, %{status: status, note: "Traffic on I-5"})
      end
    end

    test "a status with no required note may omit one", ctx do
      assert {:ok, _event} = declare(ctx.actor, ctx.driver, %{status: :AVAILABLE})
    end

    test "occurred_at more than five minutes ahead is refused", ctx do
      # A device with a wrong clock would otherwise pin a status to the future
      # where nothing can supersede it.
      assert {:error, _too_far} =
               declare(ctx.actor, ctx.driver, %{
                 status: :AVAILABLE,
                 occurred_at: DateTime.add(DateTime.utc_now(), 301, :second)
               })

      assert {:ok, _within_skew} =
               declare(ctx.actor, ctx.driver, %{
                 status: :AVAILABLE,
                 occurred_at: DateTime.add(DateTime.utc_now(), 240, :second)
               })
    end

    test "a note longer than 1,000 code points is refused", ctx do
      assert {:error, _too_long} =
               declare(ctx.actor, ctx.driver, %{
                 status: :AVAILABLE,
                 note: String.duplicate("a", 1_001)
               })
    end
  end

  describe "Section 22.3: append-only and idempotent" do
    setup do
      org = carrier()
      tenant = org.id
      driver = participant(tenant, org)
      %{tenant: tenant, driver: driver, actor: actor_for(tenant, org, driver, "DRIVER")}
    end

    test "a repeated device sequence is refused", ctx do
      # Section 14: a handset that uploads, loses the response and retries must
      # not produce two declarations.
      device_id = Ash.UUID.generate()

      assert {:ok, _first} =
               declare(ctx.actor, ctx.driver, %{
                 status: :AT_PICKUP,
                 device_id: device_id,
                 device_sequence: 412
               })

      assert {:error, _duplicate} =
               declare(ctx.actor, ctx.driver, %{
                 status: :LOADING,
                 device_id: device_id,
                 device_sequence: 412
               })
    end

    test "the resource exposes no update or destroy action" do
      # Section 5.1 corrects by appending; Section 12 makes a correction a
      # compensating event. An action that existed but was policy-denied would
      # still be one refactor from being allowed.
      action_types =
        ParticipantStatusEvent
        |> Ash.Resource.Info.actions()
        |> Enum.map(& &1.type)
        |> Enum.uniq()

      refute :update in action_types
      refute :destroy in action_types
    end

    test "a correction supersedes without rewriting", ctx do
      {:ok, first} = declare(ctx.actor, ctx.driver, %{status: :AT_PICKUP})

      {:ok, correction} =
        declare(ctx.actor, ctx.driver, %{status: :EN_ROUTE_PICKUP, supersedes_event_id: first.id})

      history =
        ParticipantStatusEvent
        |> Ash.Query.for_read(:history, %{participant_id: ctx.driver.id})
        |> Ash.read!(actor: ctx.actor, tenant: ctx.tenant)

      # Both events remain readable; the original was not edited away.
      assert length(history) == 2
      assert correction.supersedes_event_id == first.id
    end
  end

  describe "Section 22.3: the audit chain" do
    setup do
      org = carrier()
      %{tenant: org.id}
    end

    defp record(tenant, type, payload \\ %{}) do
      AuditEvent
      |> Ash.Changeset.for_create(:record, %{
        tenant_id: tenant,
        event_type: type,
        actor_type: :SYSTEM,
        subject_type: "test",
        subject_id: Ash.UUID.generate(),
        occurred_at: DateTime.utc_now(),
        payload_json: payload
      })
      |> Ash.create!(authorize?: false, tenant: tenant)
    end

    test "each entry links to the previous one", ctx do
      first = record(ctx.tenant, "first.event")
      second = record(ctx.tenant, "second.event")
      third = record(ctx.tenant, "third.event")

      assert is_nil(first.previous_event_hash)
      assert second.previous_event_hash == first.event_hash
      assert third.previous_event_hash == second.event_hash
    end

    test "the chain verifies end to end", ctx do
      for n <- 1..5, do: record(ctx.tenant, "event.#{n}", %{"n" => n})

      chain =
        AuditEvent
        |> Ash.Query.for_read(:chain)
        |> Ash.read!(authorize?: false, tenant: ctx.tenant)

      chain
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [earlier, later] ->
        assert later.previous_event_hash == earlier.event_hash
      end)
    end

    test "identical facts in different tenants produce different hashes" do
      # The hash covers tenant_id, so one tenant's chain cannot be replayed into
      # another's.
      a = carrier().id
      b = carrier().id
      at = DateTime.utc_now()
      subject = Ash.UUID.generate()

      write = fn tenant ->
        AuditEvent
        |> Ash.Changeset.for_create(:record, %{
          tenant_id: tenant,
          event_type: "same.event",
          actor_type: :SYSTEM,
          subject_type: "test",
          subject_id: subject,
          occurred_at: at,
          payload_json: %{"k" => "v"}
        })
        |> Ash.create!(authorize?: false, tenant: tenant)
      end

      refute write.(a).event_hash == write.(b).event_hash
    end

    test "payload key order does not change the hash", ctx do
      # Map iteration order is unspecified; an unsorted encoding would make the
      # chain unverifiable across runs.
      at = DateTime.utc_now()
      subject = Ash.UUID.generate()

      hashes =
        for payload <- [%{"a" => 1, "b" => 2}, %{"b" => 2, "a" => 1}] do
          AuditEvent
          |> Ash.Changeset.for_create(:record, %{
            tenant_id: ctx.tenant,
            event_type: "order.test",
            actor_type: :SYSTEM,
            subject_type: "test",
            subject_id: subject,
            occurred_at: at,
            payload_json: payload
          })
          |> Ash.Changeset.for_create(:record, %{})
          |> then(fn cs -> Ash.Changeset.get_attribute(cs, :event_hash) end)
        end

      assert Enum.uniq(hashes) |> length() == 1
    end

    test "the resource exposes no update or destroy action" do
      action_types =
        AuditEvent
        |> Ash.Resource.Info.actions()
        |> Enum.map(& &1.type)
        |> Enum.uniq()

      refute :update in action_types
      refute :destroy in action_types
    end
  end
end
