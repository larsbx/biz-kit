defmodule Dispatch.Fleet.PartnerActionsTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  require Ash.Query
  alias Dispatch.Support.Fixtures, as: F
  alias Dispatch.Fleet.{PartnerActions, Stop, Load, DocumentReference, ReferenceCipher}
  alias Dispatch.Operations.StopReadinessEvent
  alias Dispatch.Communications.ActionProposal
  alias DispatchWeb.ViewModels.{PartnerStopView, PartnerLoadView}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)
    carrier = F.carrier()
    t = carrier.id

    load =
      F.load(t, carrier,
        agreed_rate_minor: 754_321,
        currency: "USD",
        external_reference: "CONTRACT-1"
      )

    pickup = F.stop(t, load, :PICKUP, sequence: 1)
    delivery = F.stop(t, load, :DELIVERY, sequence: 2)
    shipper_org = F.organization(t, :SHIPPER)
    receiver_org = F.organization(t, :RECEIVER)
    broker_org = F.organization(t, :BROKER)
    F.stop_party(t, pickup, shipper_org, :SHIPPER)
    F.stop_party(t, delivery, receiver_org, :RECEIVER)
    load_party(t, load, broker_org, :BROKER)

    shipper =
      F.actor(t, shipper_org, F.participant(t, shipper_org), "SHIPPER", scope_id: pickup.id)

    receiver =
      F.actor(t, receiver_org, F.participant(t, receiver_org), "RECEIVER", scope_id: delivery.id)

    broker = F.actor(t, broker_org, F.participant(t, broker_org), "BROKER", scope_id: load.id)

    %{
      tenant: t,
      carrier: carrier,
      load: load,
      pickup: pickup,
      delivery: delivery,
      shipper: shipper,
      receiver: receiver,
      broker: broker,
      shipper_org: shipper_org,
      receiver_org: receiver_org,
      broker_org: broker_org
    }
  end

  defp readiness(version \\ 0), do: %{"state" => "READY", "expected_version" => version}

  defp window(version \\ 0),
    do: %{
      "kind" => "APPOINTMENT",
      "expected_version" => version,
      "window_start" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 7200)),
      "window_end" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 10800)),
      "expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600))
    }

  defp instructions(version \\ 0),
    do: %{
      "kind" => "INSTRUCTION",
      "expected_version" => version,
      "instructions" => "Use the east gate",
      "expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600))
    }

  defp document(version \\ 0),
    do: %{
      "category" => "PROOF_OF_DELIVERY",
      "label" => "Signed POD",
      "reference" => "POD-123",
      "expected_version" => version
    }

  defp load_party(tenant, load, org, relationship) do
    Dispatch.Fleet.LoadParty
    |> Ash.Changeset.for_create(:add, %{
      tenant_id: tenant,
      load_id: load.id,
      organization_id: org.id,
      relationship: relationship,
      starts_at: DateTime.add(DateTime.utc_now(), -3600)
    })
    |> Ash.create!(authorize?: false, tenant: tenant)
  end

  defp raw(resource, tenant), do: Ash.read!(resource, tenant: tenant, authorize?: false)

  test "readiness is attributed, append-only, audited, and never a driver declaration", c do
    assert {:ok, event} = PartnerActions.submit(c.shipper, c.pickup.id, :readiness, readiness())
    assert event.participant_id == c.shipper.principal_id
    assert event.role_assignment_id == c.shipper.role_assignment.id
    assert event.source == :PARTICIPANT
    assert event.recorded_at
    assert {:ok, view} = PartnerStopView.build(c.shipper, c.pickup.id)
    assert view.readiness == :READY
    assert view.readiness_summary.occurred_at == event.occurred_at
    assert [] == raw(Dispatch.Operations.ParticipantStatusEvent, c.tenant)

    assert [%{event_type: "partner.readiness.submitted"}] =
             raw(Dispatch.Audit.AuditEvent, c.tenant)

    assert [] ==
             Enum.filter(
               Ash.Resource.Info.actions(StopReadinessEvent),
               &(&1.type in [:update, :destroy])
             )
  end

  test "the receiver can report delivery readiness", c do
    assert {:ok, _} = PartnerActions.submit(c.receiver, c.delivery.id, :readiness, readiness())
  end

  test "a window proposal leaves the confirmed window and instructions intact", c do
    assert {:ok, proposal} = PartnerActions.submit(c.shipper, c.pickup.id, :proposal, window())
    assert proposal.state == :PROPOSED

    assert proposal.payload_sha256 ==
             Base.encode16(:crypto.hash(:sha256, proposal.canonical_payload), case: :lower)

    stop = Ash.get!(Stop, c.pickup.id, tenant: c.tenant, authorize?: false)
    assert stop.window_start == c.pickup.window_start
    assert stop.address_text == c.pickup.address_text

    assert [] ==
             Enum.filter(
               Ash.Resource.Info.actions(ActionProposal),
               &(&1.type in [:update, :destroy])
             )
  end

  test "proof references are encrypted, scoped and explicitly unverified", c do
    assert {:ok, record} = PartnerActions.submit(c.receiver, c.delivery.id, :document, document())
    refute record.object_reference_ciphertext =~ "POD-123"
    assert ReferenceCipher.decrypt(record.object_reference_ciphertext) == {:ok, "POD-123"}
    assert record.scan_state == :REFERENCE_ONLY
    assert {:ok, view} = PartnerStopView.build(c.receiver, c.delivery.id)
    assert [%{reference: "POD-123"}] = view.documents
    assert {:ok, pickup_view} = PartnerStopView.build(c.shipper, c.pickup.id)
    assert [] == pickup_view.documents
  end

  test "URL content is not accepted as a proof locator", c do
    assert {:error, _} =
             PartnerActions.submit(
               c.receiver,
               c.delivery.id,
               :document,
               Map.put(document(), "reference", "javascript:alert(1)")
             )

    assert [] == raw(DocumentReference, c.tenant)
  end

  test "reference storage without an encryption key fails closed", c do
    key = Application.get_env(:dispatch, :document_reference_key)
    Application.delete_env(:dispatch, :document_reference_key)
    on_exit(fn -> Application.put_env(:dispatch, :document_reference_key, key) end)
    assert {:error, _} = PartnerActions.submit(c.receiver, c.delivery.id, :document, document())
    assert [] == raw(DocumentReference, c.tenant)
  end

  test "proof category must match the stop", c do
    assert {:error, _} = PartnerActions.submit(c.shipper, c.pickup.id, :document, document())
  end

  test "proposals cannot supply approval, execution or confirmed fields", c do
    for {key, value} <- [
          {"state", "APPROVED"},
          {"approved", true},
          {"executed_at", DateTime.utc_now()},
          {"participant_id", c.receiver.principal_id},
          {"tenant_id", c.tenant}
        ] do
      assert {:error, _} =
               PartnerActions.submit(
                 c.shipper,
                 c.pickup.id,
                 :proposal,
                 Map.put(window(), key, value)
               )
    end

    assert [] == raw(ActionProposal, c.tenant)
  end

  test "a direct Ash call cannot spoof the actor or bypass the policy", c do
    params = %{stop_id: c.delivery.id, state: :READY, expected_version: 0}

    assert {:error, _refused} =
             StopReadinessEvent
             |> Ash.Changeset.for_create(:submit, params, actor: c.shipper, tenant: c.tenant)
             |> Ash.create()

    assert {:error, _} =
             StopReadinessEvent
             |> Ash.Changeset.for_create(
               :submit,
               Map.put(params, :participant_id, c.receiver.principal_id),
               actor: c.shipper,
               tenant: c.tenant
             )
             |> Ash.create()

    assert {:error, _} =
             StopReadinessEvent
             |> Ash.Changeset.for_create(:submit, params, tenant: c.tenant)
             |> Ash.create()
  end

  test "readiness compares the form's last event, including an absent initial value", c do
    assert {:ok, first} = PartnerActions.submit(c.shipper, c.pickup.id, :readiness, readiness())

    assert {:error, error} =
             PartnerActions.submit(c.shipper, c.pickup.id, :readiness, readiness())

    assert inspect(error) =~ "STALE_VERSION"

    assert {:ok, _} =
             PartnerActions.submit(
               c.shipper,
               c.pickup.id,
               :readiness,
               Map.merge(readiness(), %{"expected_latest_id" => first.id, "state" => "BLOCKED"})
             )

    assert length(raw(StopReadinessEvent, c.tenant)) == 2
  end

  test "late offline reports retain their time and do not displace a newer report", c do
    assert {:ok, first} = PartnerActions.submit(c.shipper, c.pickup.id, :readiness, readiness())

    assert {:ok, _} =
             PartnerActions.submit(
               c.shipper,
               c.pickup.id,
               :readiness,
               Map.merge(readiness(), %{
                 "expected_latest_id" => first.id,
                 "state" => "NOT_READY",
                 "occurred_at" => DateTime.to_iso8601(DateTime.add(first.occurred_at, -7200))
               })
             )

    assert {:ok, view} = PartnerStopView.build(c.shipper, c.pickup.id)
    assert view.readiness == :READY
  end

  test "missing or old stop versions are refused", c do
    assert {:error, _} =
             PartnerActions.submit(
               c.shipper,
               c.pickup.id,
               :proposal,
               Map.delete(window(), "expected_version")
             )

    changed =
      c.pickup
      |> Ash.Changeset.for_update(:update_instructions, %{
        address_text: "Changed confirmed detail"
      })
      |> Ash.update!(tenant: c.tenant, authorize?: false)

    assert changed.version == 1
    assert {:error, error} = PartnerActions.submit(c.shipper, c.pickup.id, :proposal, window())
    assert inspect(error) =~ "STALE_VERSION"
    assert [] == raw(ActionProposal, c.tenant)
  end

  test "an expired proposal is refused; expiry and stale basis are visible on existing proposals",
       c do
    assert {:error, _} =
             PartnerActions.submit(
               c.shipper,
               c.pickup.id,
               :proposal,
               Map.put(
                 window(),
                 "expires_at",
                 DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -1))
               )
             )

    assert {:ok, proposal} =
             PartnerActions.submit(c.shipper, c.pickup.id, :proposal, instructions())

    assert {:ok, view} = PartnerStopView.build(c.shipper, c.pickup.id)
    assert [%{state: :PROPOSED}] = view.proposals

    c.pickup
    |> Ash.Changeset.for_update(:update_instructions, %{address_text: "Updated"})
    |> Ash.update!(tenant: c.tenant, authorize?: false)

    assert {:ok, stale} = PartnerStopView.build(c.shipper, c.pickup.id)
    assert [%{state: :STALE}] = stale.proposals
    future_actor = %{c.shipper | at: DateTime.add(proposal.expires_at, 1)}
    assert [%{state: :EXPIRED}] = PartnerStopView.proposals(future_actor, c.pickup)
  end

  test "window ordering, kind and payload shape are validated", c do
    w = window()

    for params <- [
          Map.put(w, "kind", "ACCEPT_LOAD"),
          Map.put(w, "window_end", w["window_start"]),
          Map.put(w, "instructions", "mixed payload"),
          Map.delete(instructions(), "instructions")
        ] do
      assert {:error, _} = PartnerActions.submit(c.shipper, c.pickup.id, :proposal, params)
    end
  end

  test "shipper, receiver and broker capability boundaries", c do
    assert {:error, :not_found} =
             PartnerActions.submit(c.shipper, c.delivery.id, :readiness, readiness())

    assert {:error, :not_found} =
             PartnerActions.submit(c.receiver, c.pickup.id, :document, document())

    assert {:error, _} = PartnerActions.submit(c.broker, c.pickup.id, :readiness, readiness())
    assert {:error, _} = PartnerActions.submit(c.broker, c.delivery.id, :document, document())
    assert {:ok, _} = PartnerActions.submit(c.broker, c.pickup.id, :proposal, window())
    assert {:ok, _} = PartnerActions.submit(c.broker, c.delivery.id, :proposal, instructions())
  end

  test "kind and relationship are independent from a mis-scoped role assignment", c do
    # A deliberately bad grant must not make SHIPPER valid at a DELIVERY stop.
    F.stop_party(c.tenant, c.delivery, c.shipper_org, :SHIPPER)
    person = F.participant(c.tenant, c.shipper_org)

    bad =
      F.actor(c.tenant, c.shipper_org, person, "SHIPPER",
        scope_id: c.delivery.id,
        definition: c.shipper.role_assignment.role_definition
      )

    assert {:error, _} = PartnerActions.submit(bad, c.delivery.id, :readiness, readiness())
  end

  test "the broker sees only its selected contracted load and no sensitive operational fields",
       c do
    unrelated = F.load(c.tenant, c.carrier, external_reference: "UNRELATED-SECRET")
    assert {:ok, [view]} = PartnerLoadView.list(c.broker)
    assert view.load_id == c.load.id
    refute inspect(view) =~ "754321"
    refute inspect(view) =~ "USD"
    refute Map.has_key?(view, :route)
    refute Map.has_key?(view, :timeline)
    assert view.location_summary == nil
    assert view.communications == []

    assert PartnerLoadView.build(c.broker, unrelated.id) ==
             PartnerLoadView.build(c.broker, Ash.UUID.generate())

    assert {:ok,
            [
              %{
                agreed_rate_minor: %Ash.ForbiddenField{},
                currency: %Ash.ForbiddenField{},
                commodity_text: %Ash.ForbiddenField{}
              }
            ]} =
             Load |> Ash.Query.for_read(:partner) |> Ash.read(actor: c.broker, tenant: c.tenant)

    assert {:ok, []} =
             Load
             |> Ash.Query.for_read(:partner)
             |> Ash.Query.filter(id == ^unrelated.id)
             |> Ash.read(actor: c.broker, tenant: c.tenant)
  end

  test "proposals from other parties never appear in a broker's view", c do
    assert {:ok, _} = PartnerActions.submit(c.shipper, c.pickup.id, :proposal, instructions())
    assert {:ok, view} = PartnerLoadView.build(c.broker, c.load.id)
    refute inspect(view) =~ "Use the east gate"
  end

  test "an additional relationship never widens the selected scope", c do
    other = F.load(c.tenant, c.carrier)
    load_party(c.tenant, other, c.broker_org, :BROKER)
    assert {:error, :not_found} = PartnerLoadView.build(c.broker, other.id)
  end

  test "unrelated organizations, tenants and missing records return the same refusal", c do
    elsewhere = F.carrier()
    foreign = F.stop(elsewhere.id, F.load(elsewhere.id, elsewhere), :PICKUP, sequence: 1)

    for id <- [c.delivery.id, foreign.id, Ash.UUID.generate()] do
      assert {:error, :not_found} = PartnerActions.submit(c.shipper, id, :proposal, window())
    end
  end

  test "revoked assignments and ended relationships invalidate cached actors", c do
    F.revoke(c.tenant, c.shipper.role_assignment)

    assert {:error, :not_found} =
             PartnerActions.submit(c.shipper, c.pickup.id, :readiness, readiness())

    F.end_stop_party(c.tenant, c.delivery, c.receiver_org)

    assert {:error, :not_found} =
             PartnerActions.submit(c.receiver, c.delivery.id, :proposal, instructions())
  end

  test "inactive and administrative principals have no partner write or read", c do
    admin = F.actor(c.tenant, c.carrier, F.participant(c.tenant, c.carrier), "ADMIN")
    assert {:error, :not_found} = PartnerStopView.build(admin, c.pickup.id)

    assert {:error, :not_found} =
             PartnerActions.submit(admin, c.pickup.id, :readiness, readiness())
  end

  test "conversation reads require the selected load, its active contract and the thread's organization",
       c do
    alias Dispatch.Communications.Conversation

    own =
      Conversation
      |> Ash.Changeset.for_create(:open, %{
        tenant_id: c.tenant,
        load_id: c.load.id,
        organization_id: c.broker_org.id,
        subject: "Own thread",
        channel: :SMS
      })
      |> Ash.create!(authorize?: false, tenant: c.tenant)

    Conversation
    |> Ash.Changeset.for_create(:open, %{
      tenant_id: c.tenant,
      load_id: c.load.id,
      organization_id: c.shipper_org.id,
      subject: "PRIVATE SHIPPER THREAD",
      channel: :SMS
    })
    |> Ash.create!(authorize?: false, tenant: c.tenant)

    assert [%{id: id}] = Ash.read!(Conversation, actor: c.broker, tenant: c.tenant)
    assert id == own.id
    assert {:ok, view} = PartnerLoadView.build(c.broker, c.load.id)

    assert [%{subject: "Own thread", source: :OBSERVED, occurred_at: %DateTime{}}] =
             view.communications

    assert {:error, _} =
             Conversation
             |> Ash.Changeset.for_create(
               :open,
               %{
                 tenant_id: c.tenant,
                 load_id: c.load.id,
                 organization_id: c.broker_org.id,
                 subject: "Forged",
                 channel: :SMS
               },
               actor: c.broker,
               tenant: c.tenant
             )
             |> Ash.create()

    Dispatch.Fleet.LoadParty
    |> Ash.Query.filter(load_id == ^c.load.id and organization_id == ^c.broker_org.id)
    |> Ash.read!(authorize?: false, tenant: c.tenant)
    |> Enum.each(fn party ->
      party
      |> Ash.Changeset.for_update(:end_relationship, %{})
      |> Ash.update!(authorize?: false, tenant: c.tenant)
    end)

    assert [] == Ash.read!(Conversation, actor: c.broker, tenant: c.tenant)
    assert {:error, :not_found} = PartnerLoadView.build(c.broker, c.load.id)
  end
end
