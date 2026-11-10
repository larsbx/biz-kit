defmodule RestaurantHost.Slice5GateTest do
  @moduledoc """
  Slice 5's gate: a delivery order is placed on the web, prepared on the board,
  handed to Dispatch and completed or failed only by Dispatch's signed,
  proof-backed steps; cancellation goes through Dispatch once it has accepted.
  Dispatch is played by the test with a transport key the host never holds.
  """
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias CoopSubstrate.{Crypto, Log}
  alias CoopSubstrate.Protocol.Envelope
  alias RestaurantCore.{Admission, Coupling}
  alias RestaurantHost.{Orders, Restaurant, World}

  @endpoint RestaurantHost.Web.Endpoint

  setup do
    {:ok,
     World.build(delivery: %{fee_minor: 399}, transport: true) |> Map.put(:conn, build_conn())}
  end

  defp board(ctx) do
    conn = get(ctx.conn, "/board/pair/board-1/#{ctx.secret}")
    {:ok, board, _} = live(recycle(conn), "/board")
    board
  end

  defp click(view, id), do: view |> element("##{id}") |> render_click()

  # Every delivery order's (state, handoff view) pair is coupled.
  defp coupled!(ctx) do
    for %{fulfillment: :delivery} = o <- Orders.list(ctx.restaurant) do
      view = if o.handoff, do: o.handoff.view, else: :none
      assert Coupling.coupled?(:delivery, o.state, view), inspect({o.id, o.state, view})
    end
  end

  defp ready_order(ctx, board, key) do
    {:ok, id} =
      Orders.place(ctx.restaurant, %{"margherita" => 1}, "Ada", key, %{address: "1 Main St"})

    for action <- ~w(accept start_preparing mark_ready), do: click(board, "#{action}-#{id}")
    id
  end

  test "ordered for delivery on the web, handed to Dispatch, delivered with proof", ctx do
    {:ok, store, _} = live(ctx.conn, "/")
    click(store, "add-margherita")
    click(store, "add-margherita")
    store |> form("#place", %{fulfillment: "delivery"}) |> render_change()
    assert store |> element("#delivery-fee") |> render() =~ "3.99"
    assert store |> element("#total") |> render() =~ "30.49"

    store
    |> form("#place", %{
      name: "Ada",
      fulfillment: "delivery",
      address: "1 Main St",
      notes: "Side door"
    })
    |> render_submit()

    assert render(store) =~ "cash on delivery"
    [%{id: id, total: 3049, delivery: %{"address" => "1 Main St"}}] = Orders.list(ctx.restaurant)

    board = board(ctx)
    assert board |> element("#order-#{id}") |> render() =~ "1 Main St"
    for action <- ~w(accept start_preparing mark_ready), do: click(board, "#{action}-#{id}")
    refute has_element?(board, "#complete-#{id}")
    click(board, "request_transport-#{id}")
    assert render(board) =~ "Driver requested"
    assert render(store) =~ "Waiting for a driver"

    World.transport!(ctx, id, "accept")
    assert %{state: :ready, handoff: %{view: :accepted}} = Orders.get(ctx.restaurant, id)
    assert render(board) =~ "Driver assigned"

    World.transport!(ctx, id, "in_transit")
    assert %{state: :dispatched} = Orders.get(ctx.restaurant, id)
    assert render(store) =~ "On its way"
    refute board |> element("#order-#{id}") |> render() =~ "<button"

    World.transport!(ctx, id, "delivered")

    assert %{state: :completed, handoff: %{view: :delivered, proof: <<_::512>>}} =
             Orders.get(ctx.restaurant, id)

    assert render(store) =~ "Delivered"
    refute has_element?(board, "#order-#{id}")
    coupled!(ctx)
  end

  test "a failure needs a reason and proof; before pickup it holds the order, in transit it fails it",
       ctx do
    board = board(ctx)
    id = ready_order(ctx, board, "k1")
    click(board, "request_transport-#{id}")
    World.transport!(ctx, id, "accept")
    World.transport!(ctx, id, "failed")

    assert %{state: :ready, handoff: %{view: :failed_before_pickup}} =
             Orders.get(ctx.restaurant, id)

    assert render(board) =~ "Driver failed: nobody home"

    click(board, "request_transport-#{id}")
    World.transport!(ctx, id, "accept")
    World.transport!(ctx, id, "in_transit")
    assert World.transport(ctx, id, "failed", %{"proof" => nil}) == {:error, :proof_required}
    assert World.transport(ctx, id, "delivered", %{"proof" => nil}) == {:error, :proof_required}
    World.transport!(ctx, id, "failed")

    assert %{state: :failed, handoff: %{view: :failed_in_transit}} =
             Orders.get(ctx.restaurant, id)

    coupled!(ctx)
  end

  test "cancelling: at once before Dispatch accepts, through Dispatch after, never after pickup",
       ctx do
    board = board(ctx)

    early = ready_order(ctx, board, "k1")
    click(board, "request_transport-#{early}")
    click(board, "cancel-#{early}")
    assert %{state: :cancelled, handoff: %{view: :withdrawn}} = Orders.get(ctx.restaurant, early)
    assert World.transport(ctx, early, "accept") == {:error, :order_cancelled}
    World.transport!(ctx, early, "cancel_confirmed")

    late = ready_order(ctx, board, "k2")
    click(board, "request_transport-#{late}")
    World.transport!(ctx, late, "accept")
    click(board, "cancel-#{late}")
    assert render(board) =~ "Cancellation pending with Dispatch"
    assert %{state: :ready, actions: [], handoff_actions: []} = Orders.get(ctx.restaurant, late)
    assert World.transport(ctx, late, "in_transit") == {:error, :cancel_pending}
    World.transport!(ctx, late, "cancel_confirmed")
    assert render(board) =~ "Dispatch confirmed the cancellation"
    refute has_element?(board, "#request_transport-#{late}")
    click(board, "cancel-#{late}")
    assert %{state: :cancelled, handoff: %{view: :cancelled}} = Orders.get(ctx.restaurant, late)

    gone = ready_order(ctx, board, "k3")
    click(board, "request_transport-#{gone}")
    World.transport!(ctx, gone, "accept")
    World.transport!(ctx, gone, "in_transit")
    refute has_element?(board, "#cancel-#{gone}")

    assert Orders.cancel(ctx.restaurant, "board-1", gone, "too late") ==
             {:error, :invalid_transition}

    coupled!(ctx)
  end

  test "the guest sees a cancellation requested after Dispatch accepted, until the board finishes it",
       ctx do
    {:ok, store, _} = live(ctx.conn, "/")
    click(store, "add-margherita")
    store |> form("#place", %{fulfillment: "delivery"}) |> render_change()

    store
    |> form("#place", %{name: "Ada", fulfillment: "delivery", address: "1 Main St"})
    |> render_submit()

    [%{id: id}] = Orders.list(ctx.restaurant)

    board = board(ctx)

    for action <- ~w(accept start_preparing mark_ready request_transport),
        do: click(board, "#{action}-#{id}")

    World.transport!(ctx, id, "accept")
    click(board, "cancel-#{id}")
    assert render(store) =~ "Cancellation requested"
    World.transport!(ctx, id, "cancel_confirmed")
    assert render(store) =~ "Cancellation requested"
    click(board, "cancel-#{id}")
    assert render(store) =~ "Cancelled"
  end

  test "a snapshot whose delivery text is not text renders as blank, not a crash", ctx do
    r = Restaurant.current()
    board = board(ctx)
    {:ok, id} = Orders.place(r, %{"margherita" => 1}, "Ada", "k1", %{address: "1 Main St"})
    %{lines: lines, adjustments: adj} = Orders.get(r, id)

    payload = %{
      "merchant_id" => "shop",
      "order_id" => "odd",
      "cart_id" => "odd",
      "principal_id" => "guest:odd",
      "channel" => "web",
      "idempotency_key" => "odd",
      "fulfillment" => "delivery",
      "delivery" => %{"address" => %{"street" => 1}, "notes" => 7},
      "currency" => "USD",
      "lines" => [%{hd(lines) | "name" => %{}}],
      "subtotal_minor" => 1250,
      "total_minor" => 1250 + adj.tax_total + adj.delivery_fee,
      "adjustments" => Map.new(adj, fn {k, v} -> {Atom.to_string(k), v} end)
    }

    {:ok, env} =
      Envelope.new(%{
        event_id: CoopSubstrate.ULID.generate(),
        chapter_id: r.chapter,
        type: "RestaurantOrderPlacedV1",
        payload: payload,
        signers: [r.storefront.signer],
        auth_ref: nil,
        timestamp_ms: System.system_time(:millisecond)
      })

    {:ok, signed} = Envelope.sign(env, r.storefront.signer.key_id, r.storefront.seed)
    assert {:ok, _} = Log.append(signed)
    assert board |> element("#order-odd") |> render() =~ "Deliver to"
    assert has_element?(board, "#accept-odd")
  end

  test "the host holds no Dispatch key, and no restaurant key can act as one", ctx do
    r = Restaurant.current()
    seeds = [r.storefront.seed | Enum.map(Map.values(r.boards), & &1.seed)]
    refute ctx.transport.signer.pubkey in Enum.map(seeds, &Crypto.pubkey_from_seed/1)
    refute Map.has_key?(Map.from_struct(r), :transport)

    board = board(ctx)
    id = ready_order(ctx, board, "k1")
    click(board, "request_transport-#{id}")

    for device <- [r.storefront | Map.values(r.boards)] do
      as_dispatch = %{seed: device.seed, signer: %{device.signer | role: "dispatch_transport"}}
      assert World.transport(ctx, id, "accept", %{}, as_dispatch) == {:error, :forbidden}
    end

    stranger = World.grant_transport(ctx, "other-shop", "dispatch-other")
    assert World.transport(ctx, id, "accept", %{}, stranger) == {:error, :forbidden}

    granted = Admission.transport?(Log.gate().restaurant, ctx.chapter, "shop")
    assert granted
    coupled!(ctx)
  end

  test "without a transport grant the storefront offers pickup only" do
    ctx = World.build(delivery: %{fee_minor: 399}) |> Map.put(:conn, build_conn())
    {:ok, store, html} = live(ctx.conn, "/")
    refute html =~ "Delivery"
    click(store, "add-margherita")
    refute has_element?(store, "#fulfillment-delivery")

    assert Orders.place(ctx.restaurant, %{"margherita" => 1}, "Ada", "k1", %{address: "1 Main St"}) ==
             {:error, :delivery_unavailable}
  end
end
