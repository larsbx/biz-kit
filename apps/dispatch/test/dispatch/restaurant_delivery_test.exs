defmodule Dispatch.RestaurantDeliveryTest do
  use ExUnit.Case, async: false

  alias Dispatch.Fleet.{Assignment, Load, PartnerActions}
  alias Dispatch.RestaurantDelivery
  alias Dispatch.Support.Fixtures, as: F

  @moduletag :integration

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)
    carrier = F.carrier()
    tenant = carrier.id
    config = %{chapter: "chapter", merchant: "shop", tenant: tenant}
    order = "order-1"
    reference = RestaurantDelivery.load_reference(config.chapter, config.merchant, order)
    load = load(tenant, reference)
    other_load = load(tenant, "other-reference")
    operator = F.participant(tenant, carrier)

    assignment =
      Assignment
      |> Ash.Changeset.for_create(:plan, %{
        tenant_id: tenant,
        load_id: load.id,
        operator_participant_id: operator.id,
        starts_at: DateTime.utc_now()
      })
      |> Ash.create!(authorize?: false, tenant: tenant)

    pickup = F.stop(tenant, load, :PICKUP, sequence: 1)
    dropoff = F.stop(tenant, load, :DELIVERY, sequence: 2)
    wrong = F.stop(tenant, other_load, :DELIVERY, sequence: 1)

    %{
      config: config,
      assignment: assignment,
      pickup: document(tenant, pickup, :SHIPPER, "PICKUP_DOCUMENT"),
      dropoff: document(tenant, dropoff, :RECEIVER, "PROOF_OF_DELIVERY"),
      wrong: document(tenant, wrong, :RECEIVER, "PROOF_OF_DELIVERY"),
      input: %{"order_id" => order, "load_id" => load.id, "assignment_id" => assignment.id}
    }
  end

  test "matches the actual Dispatch load, assignment, stop, and document", c do
    accept = Map.put(c.input, "op", "accept")
    pickup = Map.merge(c.input, %{"op" => "picked_up", "proof_id" => c.pickup.id})
    dropoff = Map.merge(c.input, %{"op" => "delivered", "proof_id" => c.dropoff.id})

    assert {:error, :dispatch_source_not_confirmed} =
             RestaurantDelivery.confirm_source(accept, c.config)

    active = move(c.assignment, :activate, c.config.tenant)
    assert :ok = RestaurantDelivery.confirm_source(accept, c.config)
    assert :ok = RestaurantDelivery.confirm_source(pickup, c.config)

    assert {:error, :dispatch_source_not_confirmed} =
             RestaurantDelivery.confirm_source(dropoff, c.config)

    move(active, :complete, c.config.tenant)
    assert :ok = RestaurantDelivery.confirm_source(dropoff, c.config)

    for {input, config} <- [
          {%{dropoff | "proof_id" => c.wrong.id}, c.config},
          {%{dropoff | "proof_id" => c.pickup.id}, c.config},
          {%{dropoff | "order_id" => "other-order"}, c.config},
          {dropoff, %{c.config | merchant: "other-shop"}},
          {dropoff, %{c.config | tenant: Ash.UUID.generate()}}
        ] do
      assert {:error, :dispatch_source_not_confirmed} =
               RestaurantDelivery.confirm_source(input, config)
    end
  end

  defp move(assignment, action, tenant) do
    assignment
    |> Ash.Changeset.for_update(action, %{expected_version: assignment.version})
    |> Ash.update!(authorize?: false, tenant: tenant)
  end

  defp load(tenant, reference) do
    Load
    |> Ash.Changeset.for_create(:create_load, %{
      tenant_id: tenant,
      carrier_organization_id: tenant,
      external_reference: reference
    })
    |> Ash.create!(authorize?: false, tenant: tenant)
  end

  defp document(tenant, stop, relationship, category) do
    org = F.organization(tenant, relationship)
    F.stop_party(tenant, stop, org, relationship)

    actor =
      F.actor(tenant, org, F.participant(tenant, org), Atom.to_string(relationship),
        scope_id: stop.id
      )

    {:ok, doc} =
      PartnerActions.submit(actor, stop.id, :document, %{
        "category" => category,
        "label" => "Operator will review",
        "reference" => "operator-review-document",
        "expected_version" => stop.version
      })

    doc
  end
end
