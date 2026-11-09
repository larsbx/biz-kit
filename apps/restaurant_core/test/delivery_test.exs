defmodule RestaurantCore.DeliveryTest do
  use ExUnit.Case, async: true

  alias RestaurantCore.{Admission, Delivery, Kitchen}

  @tenant "11111111-1111-1111-1111-111111111111"
  @load "22222222-2222-2222-2222-222222222222"
  @assignment "55555555-5555-5555-5555-555555555555"
  @pickup "33333333-3333-3333-3333-333333333333"
  @dropoff "44444444-4444-4444-4444-444444444444"
  @gov %{key_id: "gov", pubkey: <<1::256>>}
  @dispatch %{key_id: "dispatch", pubkey: <<2::256>>}

  defp operation(op, version, extra \\ %{}) do
    Map.merge(
      %{
        "op" => op,
        "command_id" => op,
        "expected_version" => version,
        "load_id" => @load,
        "assignment_id" => @assignment,
        "tenant_id" => @tenant,
        "merchant_id" => "shop",
        "order_id" => "order"
      },
      extra
    )
  end

  defp ready(id \\ "order") do
    {:ok, order} = Kitchen.new("shop", id, :delivery)
    %{order | state: :ready, version: 3}
  end

  test "handoff gates the mirror by the exact load, proof, phase and revision" do
    initial = Delivery.init()
    order = ready()
    accept = operation("accept", 0)
    pickup = operation("picked_up", 1, %{"proof_id" => @pickup})
    delivered = operation("delivered", 2, %{"proof_id" => @dropoff})

    assert {:error, :delivery_order_not_ready} =
             Delivery.apply(initial, "chapter", "shop", %{order | state: :preparing}, accept)

    assert {:ok, booked, ^order} = Delivery.apply(initial, "chapter", "shop", order, accept)

    assert {:error, :duplicate_delivery_step} =
             Delivery.apply(booked, "chapter", "shop", order, accept)

    assert {:error, :wrong_delivery_transport} =
             Delivery.apply(booked, "chapter", "shop", ready("another-order"), accept)

    assert {:error, :stale_fulfillment_version} =
             Delivery.apply(booked, "chapter", "shop", order, delivered)

    assert {:error, :invalid_fulfillment_transition} =
             Delivery.apply(booked, "chapter", "shop", order, %{
               delivered
               | "expected_version" => 1
             })

    assert {:error, :wrong_delivery_transport} =
             Delivery.apply(booked, "chapter", "shop", order, %{pickup | "tenant_id" => @dropoff})

    assert {:error, :invalid_dispatch_evidence} =
             Delivery.apply(booked, "chapter", "shop", order, Map.delete(pickup, "proof_id"))

    assert {:ok, moving, %{state: :dispatched, version: 4} = out} =
             Delivery.apply(booked, "chapter", "shop", order, pickup)

    assert {:error, :dispatch_proof_already_used} =
             Delivery.apply(moving, "chapter", "shop", out, %{delivered | "proof_id" => @pickup})

    assert {:ok, final, %{state: :completed, version: 5} = completed} =
             Delivery.apply(moving, "chapter", "shop", out, delivered)

    assert %{version: 3, proof_ref: @dropoff, phase: :delivered} =
             Delivery.handoff(final, "chapter", "shop", order.id)

    assert {:error, :duplicate_delivery_step} =
             Delivery.apply(final, "chapter", "shop", completed, delivered)

    assert {:error, :idempotency_conflict} =
             Delivery.apply(final, "chapter", "shop", completed, %{
               delivered
               | "proof_id" => @load
             })
  end

  test "the signed gate scopes transport authority to chapter, merchant and tenant" do
    original = Admission.init()

    gate = %{
      role_keys: %{{"chapter", "governance"} => %{"gov" => @gov.pubkey}},
      restaurant:
        put_in(original, [:merchants, {"chapter", "shop"}], %{orders: %{"order" => ready()}})
    }

    grant = %{
      type: "RestaurantDispatchGrantedV1",
      signers: [@gov],
      chapter_id: "chapter",
      payload: %{
        "merchant_id" => "shop",
        "tenant_id" => @tenant,
        "key_id" => @dispatch.key_id,
        "pubkey" => {:bytes, @dispatch.pubkey}
      }
    }

    step = %{
      type: "RestaurantDeliveryStepV1",
      signers: [@dispatch],
      chapter_id: "chapter",
      payload: operation("accept", 0)
    }

    assert {:error, :forbidden} = Admission.check(step, gate)
    assert :ok = Admission.check(grant, gate)
    granted = %{gate | restaurant: Admission.fold(grant, gate)}
    refute Admission.active_device?(granted.restaurant, "chapter", "shop", @dispatch)
    assert Admission.dispatch_available?(granted.restaurant, "chapter", "shop")

    for unauthorized <- [
          %{step | chapter_id: "other"},
          put_in(step.payload["merchant_id"], "other"),
          put_in(step.payload["tenant_id"], @load),
          %{step | signers: [%{@dispatch | pubkey: @gov.pubkey}]}
        ] do
      assert {:error, :forbidden} = Admission.check(unauthorized, granted)
    end

    assert :ok = Admission.check(step, granted)
    accepted = %{granted | restaurant: Admission.fold(step, granted)}

    revoke = %{
      grant
      | type: "RestaurantDeviceRevokedV1",
        payload: %{"merchant_id" => "shop", "key_id" => @dispatch.key_id}
    }

    assert :ok = Admission.check(revoke, accepted)
    revoked = %{accepted | restaurant: Admission.fold(revoke, accepted)}
    refute Admission.dispatch_available?(revoked.restaurant, "chapter", "shop")
    assert {:error, :forbidden} = Admission.check(step, revoked)
  end
end
