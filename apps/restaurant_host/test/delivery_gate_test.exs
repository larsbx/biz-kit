defmodule RestaurantHost.DeliveryGateTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias CoopSubstrate.{Canonical, Crypto}
  alias CoopSubstrate.Protocol.Envelope
  alias RestaurantHost.{Management, Orders, World}

  @endpoint RestaurantHost.Web.Endpoint
  @tenant "11111111-1111-1111-1111-111111111111"
  @load "22222222-2222-2222-2222-222222222222"
  @assignment "55555555-5555-5555-5555-555555555555"
  @pickup "33333333-3333-3333-3333-333333333333"
  @dropoff "44444444-4444-4444-4444-444444444444"

  test "only the scoped Dispatch signer can complete the arranged delivery" do
    %{restaurant: r, governance: gov} = World.build(delivery_enabled: true)
    {pubkey, seed} = Crypto.generate_keypair()

    assert Orders.place(r, %{"margherita" => 1}, "Ada", "key", nil, "delivery") ==
             {:error, :invalid_fulfillment}

    grant = %{
      "merchant_id" => r.merchant,
      "tenant_id" => @tenant,
      "key_id" => "dispatch",
      "pubkey" => Base.url_encode64(pubkey, padding: false)
    }

    assert {:ok, held} = Management.prepare(r, "grant-dispatch", grant, gov.signer.key_id)

    assert {:ok, _} =
             Management.submit(
               r,
               "grant-dispatch",
               held.id,
               Crypto.sign(held.signing_bytes, gov.seed)
             )

    {:ok, storefront, _} = live(build_conn(), "/")
    storefront |> element("#add-margherita") |> render_click()
    storefront |> form("#place", %{name: "Ada", fulfillment: "delivery"}) |> render_submit()
    [%{id: id, fulfillment: :delivery, state: :placed}] = Orders.list(r)
    signer = %{role: "restaurant_dispatch", key_id: "dispatch", pubkey: pubkey}

    base = %{
      "merchant_id" => r.merchant,
      "order_id" => id,
      "tenant_id" => @tenant,
      "load_id" => @load,
      "assignment_id" => @assignment,
      "command_id" => "accept",
      "op" => "accept",
      "expected_version" => 0
    }

    assert submit(r, signer, seed, base).status == 422

    for {action, version} <- Enum.with_index([:accept, :start_preparing, :mark_ready]),
        do: assert(:ok = Orders.step(r, "board-1", id, action, version))

    assert %{state: :ready, delivery: %{phase: :requested, version: 0}} = Orders.get(r, id)
    assert {:error, :delivery_owned} = Orders.step(r, "board-1", id, :complete, 3)
    {wrong_pubkey, wrong_seed} = Crypto.generate_keypair()
    assert submit(r, %{signer | pubkey: wrong_pubkey}, wrong_seed, base).status == 403
    assert submit(r, signer, seed, base).status == 201
    assert submit(r, signer, seed, base).status == 200

    assert {:error, :dispatch_custody_reconciliation_required} =
             Orders.step(r, "board-1", id, :cancel, 3, "Cancelled")

    pickup =
      Map.merge(base, %{
        "command_id" => "pickup",
        "op" => "picked_up",
        "expected_version" => 1,
        "proof_id" => @pickup
      })

    dropoff =
      Map.merge(base, %{
        "command_id" => "dropoff",
        "op" => "delivered",
        "expected_version" => 2,
        "proof_id" => @dropoff
      })

    assert submit(r, signer, seed, dropoff).status == 422
    assert submit(r, signer, seed, pickup).status == 201
    assert %{state: :dispatched} = Orders.get(r, id)
    assert submit(r, signer, seed, dropoff).status == 201
    assert %{state: :completed, delivery: %{phase: :delivered, version: 3}} = Orders.get(r, id)
    assert render(storefront) =~ "Delivered"
  end

  defp submit(r, signer, seed, payload) do
    {:ok, event} =
      Envelope.new(%{
        chapter_id: r.chapter,
        type: "RestaurantDeliveryStepV1",
        payload: payload,
        signers: [signer],
        timestamp_ms: System.system_time(:millisecond)
      })

    {:ok, signed} = Envelope.sign(event, signer.key_id, seed)

    record =
      signed
      |> Envelope.full_record_term()
      |> Canonical.encode!()
      |> Base.url_encode64(padding: false)

    build_conn()
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post("/api/restaurant-delivery", Jason.encode!(%{"record" => record}))
  end
end
