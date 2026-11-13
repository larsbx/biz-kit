defmodule RestaurantHost.BoardCancellationTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias BizKit.Identity.{Principal, Sessions}
  alias CoopSubstrate.{Crypto, Log}
  alias RestaurantHost.{Management, Orders, World}

  @endpoint RestaurantHost.Web.Endpoint

  setup do
    previous = Application.fetch_env(:restaurant_host, :staff_principals)
    Application.delete_env(:restaurant_host, :staff_principals)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:restaurant_host, :staff_principals, value)
        :error -> Application.delete_env(:restaurant_host, :staff_principals)
      end
    end)

    {:ok, World.build()}
  end

  test "the submitted cancellation form signs only its order, version, reason and staff", ctx do
    r = ctx.restaurant
    {:ok, chosen} = Orders.place(r, %{"margherita" => 1}, "Ada", "chosen")
    {:ok, other} = Orders.place(r, %{"pepperoni" => 1}, "Grace", "other")
    {principal, reference} = staff_session()

    {:ok, board, _} =
      ctx |> paired(%{"restaurant_identity" => reference}) |> live("/board")

    head = Log.head()
    board |> form("#cancel-#{chosen}", %{reason: "  Customer changed plans  "}) |> render_submit()

    assert %{state: :cancelled, version: 1} = Orders.get(r, chosen)
    assert %{state: :placed, version: 0} = Orders.get(r, other)
    refute has_element?(board, "#order-#{chosen}")
    assert has_element?(board, "#order-#{other}")

    assert {:ok, [event]} = Log.read_all(from: head.global_seq + 1)
    assert event.type == "RestaurantOrderStepV1"
    assert event.chapter_id == r.chapter

    assert %{
             "merchant_id" => "shop",
             "order_id" => ^chosen,
             "expected_version" => 0,
             "action" => "cancel",
             "reason" => "Customer changed plans",
             "staff_principal" => ^principal
           } = event.payload
  end

  test "a stale cancellation cannot append after another order action", ctx do
    r = ctx.restaurant
    {:ok, id} = Orders.place(r, %{"margherita" => 1}, "Ada", "stale")
    {:ok, board, _} = ctx |> paired() |> live("/board")
    assert has_element?(board, "#cancel-#{id}")
    stale = %{"order_id" => id, "version" => "0", "reason" => "Changed plans"}

    assert :ok = Orders.step(r, "board-1", id, :accept, 0)
    head = Log.head()

    # Submit the previously rendered payload even if the ledger broadcast has
    # refreshed the form in the meantime.
    assert render_submit(board, "cancel", stale) =~ "The action was refused"
    assert %{state: :accepted, version: 1} = Orders.get(r, id)
    assert Log.head() == head

    board |> form("#cancel-#{id}", %{reason: "Changed plans"}) |> render_submit()
    assert %{state: :cancelled, version: 2} = Orders.get(r, id)
    assert {:ok, [event]} = Log.read_all(from: head.global_seq + 1)
    assert event.payload["expected_version"] == 1
  end

  test "an unpaired board cannot forge a cancellation submission", ctx do
    r = ctx.restaurant
    {:ok, id} = Orders.place(r, %{"margherita" => 1}, "Ada", "unpaired")
    {:ok, board, _} = live(build_conn(), "/board")
    head = Log.head()

    render_submit(board, "cancel", %{
      "order_id" => id,
      "version" => "0",
      "reason" => "Changed plans"
    })

    assert has_element?(board, "#unpaired")
    assert %{state: :placed, version: 0} = Orders.get(r, id)
    assert Log.head() == head
  end

  test "staff revocation fences an already rendered cancellation", ctx do
    r = ctx.restaurant
    {:ok, id} = Orders.place(r, %{"margherita" => 1}, "Ada", "staff-revocation")
    {_principal, reference} = staff_session()

    {:ok, board, _} =
      ctx |> paired(%{"restaurant_identity" => reference}) |> live("/board")

    assert has_element?(board, "#cancel-#{id}")
    :ok = Sessions.revoke_reference(reference)
    head = Log.head()

    render_submit(board, "cancel", %{
      "order_id" => id,
      "version" => "0",
      "reason" => "Changed plans"
    })

    assert has_element?(board, "#staff-required")
    assert %{state: :placed, version: 0} = Orders.get(r, id)
    assert Log.head() == head
  end

  test "device revocation fences an already rendered cancellation", ctx do
    r = ctx.restaurant
    {:ok, id} = Orders.place(r, %{"margherita" => 1}, "Ada", "device-revocation")
    {:ok, board, _} = ctx |> paired() |> live("/board")
    assert has_element?(board, "#cancel-#{id}")
    payload = %{"merchant_id" => r.merchant, "key_id" => r.boards["board-1"].signer.key_id}

    {:ok, held} = Management.prepare(r, "revoke-device", payload, ctx.governance.signer.key_id)

    assert {:ok, _} =
             Management.submit(
               r,
               "revoke-device",
               held.id,
               Crypto.sign(held.signing_bytes, ctx.governance.seed)
             )

    head = Log.head()

    render_submit(board, "cancel", %{
      "order_id" => id,
      "version" => "0",
      "reason" => "Changed plans"
    })

    assert has_element?(board, "#unpaired")
    assert %{state: :placed, version: 0} = Orders.get(r, id)
    assert Log.head() == head
  end

  defp paired(ctx, session \\ %{}) do
    build_conn()
    |> Plug.Test.init_test_session(session)
    |> get("/board/pair/board-1/#{ctx.secret}")
    |> recycle()
  end

  defp staff_session do
    principal = Principal.new_id()
    Application.put_env(:restaurant_host, :staff_principals, [principal])

    previous_bindings = Application.fetch_env(:biz_kit_identity, :bindings)

    Application.put_env(:biz_kit_identity, :bindings, [
      %{issuer: "biz-kit-development", subject: "staff", principal: principal}
    ])

    token = Sessions.create(principal, %{issuer: "biz-kit-development", subject: "staff"})
    reference = Sessions.reference(token)

    on_exit(fn ->
      Sessions.revoke_reference(reference)

      case previous_bindings do
        {:ok, value} -> Application.put_env(:biz_kit_identity, :bindings, value)
        :error -> Application.delete_env(:biz_kit_identity, :bindings)
      end
    end)

    assert {:ok, %{principal: ^principal}} = BizKit.Identity.session_from_reference(reference)
    {principal, reference}
  end
end
