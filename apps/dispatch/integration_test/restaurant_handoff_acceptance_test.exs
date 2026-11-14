# Mix prunes umbrella siblings which are outside Dispatch's dependency graph.
# The acceptance runner compiles these test-only applications in its staged tree.
for app <- ~w(restaurant_host phoenix_live_view lazy_html fine) do
  true = Code.prepend_path(Path.join([Mix.Project.build_path(), "lib", app, "ebin"]))
end

defmodule Dispatch.RestaurantHandoffAcceptanceTest do
  use CoopSubstrate.LogCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias BizKit.Identity.Principal
  alias CoopSubstrate.{Crypto, Log}
  alias Dispatch.Fleet.{Assignment, Load}
  alias Dispatch.{RestaurantAutomation, RestaurantDelivery}
  alias Dispatch.Support.{DeliveryPortal, Fixtures, PortalIdentity}
  alias RestaurantHost.{DeliveryCodes, Management, Orders, World}

  @endpoint RestaurantHost.Web.Endpoint
  @site "Fixture receiving dock"
  @moduletag :integration

  setup_all do
    {:ok, _} = Application.ensure_all_started(:restaurant_host)

    on_exit(fn ->
      CoopSubstrate.LogCase.truncate_store!()
      CoopSubstrate.LogCase.truncate_records!()
    end)

    :ok
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Dispatch.Repo, {:shared, self()})
    :ok = PortalIdentity.setup()

    principal = Principal.new_id()
    set_env(:restaurant_host, :identity_provider, "restaurant-test")
    set_env(:biz_kit_identity, :allow_development_provider, true)

    set_env(:biz_kit_identity, :providers, %{
      "restaurant-test" => {BizKit.Identity.Providers.Development, subject: "diner"}
    })

    set_env(:biz_kit_identity, :bindings, [
      %{issuer: "biz-kit-development", subject: "diner", principal: principal}
    ])

    world = World.build(delivery_enabled: true, delivery_site: @site)
    carrier = Fixtures.carrier()
    tenant = carrier.id
    %{user: user, participant: courier} = Fixtures.person(tenant, carrier)
    courier_role = Fixtures.assignment(tenant, carrier, courier, "DRIVER")
    service = DeliveryPortal.service_role(tenant)
    {public_key, seed} = Crypto.generate_keypair()
    enroll_dispatch!(world, tenant, public_key)

    listener = start_supervised!({Bandit, plug: @endpoint, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(listener)
    seed_file = Path.join(System.tmp_dir!(), "restaurant-dispatch-#{Ash.UUID.generate()}.seed")
    File.write!(seed_file, Base.encode64(seed))
    File.chmod!(seed_file, 0o600)
    on_exit(fn -> File.rm!(seed_file) end)

    route = %{
      "RESTAURANT_DISPATCH_AUTOMATED" => "true",
      "RESTAURANT_DISPATCH_URL" => "http://127.0.0.1:#{port}",
      "RESTAURANT_DISPATCH_CHAPTER" => world.chapter,
      "RESTAURANT_DISPATCH_MERCHANT" => world.restaurant.merchant,
      "RESTAURANT_DISPATCH_TENANT" => tenant,
      "RESTAURANT_DISPATCH_KEY_ID" => "dispatch",
      "RESTAURANT_DISPATCH_SEED_FILE" => seed_file,
      "RESTAURANT_DISPATCH_SERVICE_ROLE" => service.id,
      "RESTAURANT_DISPATCH_COURIER" => courier.id,
      "RESTAURANT_DISPATCH_SITE" => @site,
      "RESTAURANT_DISPATCH_PICKUP" => "Fixture kitchen",
      "RESTAURANT_DISPATCH_DROPOFF" => @site
    }

    previous = Map.new(route, fn {key, _} -> {key, System.get_env(key)} end)
    System.put_env(route)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    Map.merge(world, %{
      principal: principal,
      tenant: tenant,
      user: user,
      courier: courier,
      courier_role: courier_role
    })
  end

  test "restaurant checkout reaches courier-confirmed delivery exactly once", c do
    pending = get(build_conn(), "/auth/login")
    uri = pending |> redirected_to() |> URI.parse()
    diner = get(recycle(pending), uri.path <> "?" <> uri.query)
    assert redirected_to(diner) == "/"

    {:ok, storefront, _} = live(recycle(diner), "/")
    storefront |> element("#add-margherita") |> render_click()

    storefront
    |> form("#place", %{name: "Fixture diner", fulfillment: "delivery"})
    |> render_submit()

    assert [%{id: order_id, principal: principal, state: :placed, fulfillment: :delivery}] =
             Orders.list(c.restaurant)

    assert principal == c.principal
    dropoff_code = DeliveryCodes.code(c.restaurant, order_id, "delivered")
    assert render(element(storefront, "#dropoff-code")) =~ dropoff_code

    paired = get(build_conn(), "/board/pair/board-1/#{c.secret}")
    {:ok, board, _} = live(recycle(paired), "/board")

    for action <- ~w(accept start_preparing mark_ready) do
      board |> element("##{action}-#{order_id}") |> render_click()
    end

    assert %{state: :ready, delivery: %{phase: :requested}} = Orders.get(c.restaurant, order_id)
    worker = start_supervised!({RestaurantAutomation, :restaurant})
    reconcile(worker)
    assert [%Load{} = load] = Ash.read!(Load, tenant: c.tenant, authorize?: false)

    assert load.external_reference ==
             RestaurantDelivery.load_reference(c.chapter, c.restaurant.merchant, order_id)

    assert [%Assignment{status: :ACTIVE} = trip] =
             Ash.read!(Assignment, tenant: c.tenant, authorize?: false)

    assert {trip.load_id, trip.operator_participant_id} == {load.id, c.courier.id}
    assert %{delivery: %{phase: :accepted}} = Orders.get(c.restaurant, order_id)

    pickup_code = DeliveryCodes.code(c.restaurant, order_id, "picked_up")
    refute pickup_code == dropoff_code
    assert_eventually(fn -> render(board) =~ pickup_code end)

    page = DeliveryPortal.login(c.user, c.courier_role)
    assert page.resp_body =~ trip.id
    accepted_head = Log.head()
    refused = DeliveryPortal.receipt(page, trip, "delivered", dropoff_code)
    assert refused.status == 422
    assert Log.head() == accepted_head

    # A fresh worker must recover the same assignment from persisted state.
    assert :ok = stop_supervised({RestaurantAutomation, :restaurant})
    worker = start_supervised!({RestaurantAutomation, :restaurant})
    reconcile(worker)
    assert Log.head() == accepted_head

    picked_up = DeliveryPortal.receipt(refused, trip, "picked_up", pickup_code)
    assert picked_up.status == 200

    assert %{state: :dispatched, delivery: %{phase: :in_transit}} =
             Orders.get(c.restaurant, order_id)

    delivered = DeliveryPortal.receipt(picked_up, trip, "delivered", dropoff_code)
    assert delivered.status == 200
    assert %{state: :completed, delivery: %{phase: :delivered}} = Orders.get(c.restaurant, order_id)
    reconcile(worker)

    assert [%{id: id, status: :COMPLETED}] =
             Ash.read!(Assignment, tenant: c.tenant, authorize?: false)

    assert id == trip.id
    assert_eventually(fn -> render(element(storefront, "#order-status")) =~ "Delivered" end)

    completed_head = Log.head()
    assert DeliveryPortal.receipt(delivered, trip, "delivered", dropoff_code).status == 200
    assert Log.head() == completed_head

    assert {:ok, events} = Log.read_all()
    steps = Enum.filter(events, &(&1.type == "RestaurantDeliveryStepV1"))
    assert Enum.map(steps, & &1.payload["op"]) == ~w(accept picked_up delivered)

    assert Enum.all?(steps, fn step ->
             step.chapter_id == c.chapter and
               step.payload["order_id"] == order_id and
               step.payload["tenant_id"] == c.tenant and
               step.payload["load_id"] == load.id and step.payload["assignment_id"] == trip.id
           end)

    assert :ok = Log.verify_chains()
  end

  defp reconcile(worker) do
    send(worker, :poll)
    assert {:restaurant, ""} = :sys.get_state(worker)
  end

  defp enroll_dispatch!(world, tenant, public_key) do
    grant = %{
      "merchant_id" => world.restaurant.merchant,
      "tenant_id" => tenant,
      "key_id" => "dispatch",
      "pubkey" => Base.url_encode64(public_key, padding: false)
    }

    gov = world.governance

    assert {:ok, held} =
             Management.prepare(world.restaurant, "grant-dispatch", grant, gov.signer.key_id)

    signature = Crypto.sign(held.signing_bytes, gov.seed)
    assert {:ok, _} = Management.submit(world.restaurant, "grant-dispatch", held.id, signature)
  end

  defp set_env(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(app, key, old)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  defp assert_eventually(predicate, remaining \\ 100)
  defp assert_eventually(predicate, 0), do: assert(predicate.())

  defp assert_eventually(predicate, remaining) do
    unless predicate.() do
      Process.sleep(20)
      assert_eventually(predicate, remaining - 1)
    end
  end
end
