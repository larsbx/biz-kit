defmodule Dispatch.ProcurementDeliveryTest do
  @moduledoc """
  The real Dispatch worker and authenticated courier portal against the real
  procurement HTTP host and PostgreSQL ledger. All people, keys, businesses,
  routes and addresses are disposable fixtures. No external delivery service
  or payment adapter is configured.

  This suite requires the separate procurement/Dispatch acceptance setup. The
  ordinary signed-endpoint release check remains a different evidence class.
  """

  use CoopSubstrate.LogCase, async: false

  import Plug.Conn
  import Plug.Test

  alias CoopSubstrate.{Canonical, Log, Procurement, ProcurementTestClock, RestaurantDeliveryWork}
  alias CoopSubstrate.Protocol.Envelope
  alias Dispatch.Access.Actor
  alias Dispatch.Accounts.RoleAssignment
  alias Dispatch.Fleet.{Assignment, Load}
  alias Dispatch.{RestaurantAutomation, RestaurantDelivery, RestaurantReceipts}
  alias Dispatch.Support.{Fixtures, PortalIdentity}
  alias ProcurementHost.Dispatch, as: Handoff

  @moduletag :integration
  @moduletag :procurement_dispatch
  @portal_path "/ui/restaurant-receipts"
  @session Plug.Session.init(
             store: :cookie,
             key: "_dispatch_session",
             signing_salt: "5xJq0pQe",
             encryption_salt: "Nn4vT2kA"
           )

  setup_all do
    :ok = Procurement.register_types!()
    {:ok, _} = Application.ensure_all_started(:coop_substrate)
    {:ok, _} = Application.ensure_all_started(:procurement_host)

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
    old_clock = Procurement.clock_ms()
    old_settings = Application.get_env(:procurement_host, :settings)
    now = tick()
    governance = new_member("governance", "procurement-worker-governance")
    operator = new_member("procurement_operator", "procurement-worker-operator")
    signer = new_member("procurement_dispatch", "procurement-worker-route")
    carrier = Fixtures.carrier()
    tenant = carrier.id
    %{user: user, participant: courier} = Fixtures.person(tenant, carrier)
    courier_role = Fixtures.assignment(tenant, carrier, courier, "DRIVER")
    service = service_role(tenant)
    {:ok, service_actor} = Actor.from_assignment(service)

    context = %{
      chapter_id: "procurement-real-worker",
      cooperative_id: "producer-coop",
      operator_id: "coordinator",
      key_id: operator.signer.key_id,
      seed: operator.seed,
      grant_version: 1,
      session_expires_at_ms: now + 3_600_000,
      login_digest: :crypto.hash(:sha256, "unused-test-coordinator-token"),
      secret_key_base: String.duplicate("procurement-real-worker-fixture-", 3)
    }

    Application.put_env(:procurement_host, :settings, context)

    append!(governance, context, "RoleKeyDeclared", %{
      "role" => "governance",
      "key_id" => governance.signer.key_id,
      "pubkey" => {:bytes, governance.signer.pubkey}
    })

    append!(governance, context, "ProcurementOperatorGrantedV1", %{
      "cooperative_id" => context.cooperative_id,
      "operator_id" => context.operator_id,
      "active" => true,
      "key_id" => operator.signer.key_id,
      "pubkey" => {:bytes, operator.signer.pubkey},
      "expires_at_ms" => now + 7_200_000,
      "expected_version" => 0
    })

    for business <- ["buyer", "supplier"] do
      append!(governance, context, "ProcurementBusinessEnrolledV1", %{
        "cooperative_id" => context.cooperative_id,
        "business_id" => business,
        "active" => true,
        "evidence_ref" => "fixture-enrollment-" <> business,
        "expected_version" => 0
      })
    end

    append!(governance, context, "ProcurementDispatchRouteV1", %{
      "cooperative_id" => context.cooperative_id,
      "tenant_id" => tenant,
      "site" => "Fixture receiving dock",
      "key_id" => signer.signer.key_id,
      "pubkey" => {:bytes, signer.signer.pubkey},
      "active" => true,
      "expected_version" => 0
    })

    listener = start_supervised!({Bandit, plug: ProcurementHost.Web, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(listener)
    seed_file = Path.join(System.tmp_dir!(), "procurement-dispatch-#{Ash.UUID.generate()}.seed")
    File.write!(seed_file, Base.encode64(signer.seed))
    File.chmod!(seed_file, 0o600)

    env = %{
      "PROCUREMENT_DISPATCH_AUTOMATED" => "true",
      "PROCUREMENT_DISPATCH_CHAPTER" => context.chapter_id,
      "PROCUREMENT_DISPATCH_COOPERATIVE" => context.cooperative_id,
      "PROCUREMENT_DISPATCH_TENANT" => tenant,
      "PROCUREMENT_DISPATCH_KEY_ID" => signer.signer.key_id,
      "PROCUREMENT_DISPATCH_SEED_FILE" => seed_file,
      "PROCUREMENT_DISPATCH_URL" => "http://127.0.0.1:#{port}",
      "PROCUREMENT_DISPATCH_SERVICE_ROLE" => service.id,
      "PROCUREMENT_DISPATCH_COURIER" => courier.id,
      "PROCUREMENT_DISPATCH_SITE" => "Fixture receiving dock",
      "PROCUREMENT_DISPATCH_PICKUP" => "Fixture supplier dock",
      "PROCUREMENT_DISPATCH_DROPOFF" => "Fixture receiving dock"
    }

    old_env = Map.new(env, fn {key, _} -> {key, System.get_env(key)} end)
    System.put_env(env)

    on_exit(fn ->
      Enum.each(old_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm(seed_file)
      ProcurementTestClock.set(old_clock)

      if is_nil(old_settings),
        do: Application.delete_env(:procurement_host, :settings),
        else: Application.put_env(:procurement_host, :settings, old_settings)
    end)

    {:ok, source} = RestaurantDelivery.configuration(:procurement)

    config =
      Map.merge(source, %{
        courier: courier.id,
        pickup: env["PROCUREMENT_DISPATCH_PICKUP"],
        dropoff: env["PROCUREMENT_DISPATCH_DROPOFF"],
        site: env["PROCUREMENT_DISPATCH_SITE"]
      })

    %{
      context: context,
      tenant: tenant,
      carrier: carrier,
      user: user,
      courier: courier,
      courier_role: courier_role,
      service: service,
      service_actor: service_actor,
      signer: signer,
      config: config
    }
  end

  test "real worker assignment and authenticated pickup/drop-off fulfill the exact quote once",
       c do
    accepted_quote = order!(c, "order-1")
    before = Log.head().global_seq
    assert {:ok, nil} = poll()
    trip = trip!(c, "order-1")
    assert trip.status == :ACTIVE
    assert trip.operator_participant_id == c.courier.id
    assert {:ok, [load]} = loads(c)
    assert load.external_reference == reference(c, "order-1")
    assert Log.head().global_seq == before + 1
    assert row(c, "order-1").accepted_quote == accepted_quote

    page = login(c.user, c.courier_role)
    assert page.resp_body =~ trip.id
    picked_up = receipt(page, trip, "picked_up", code(c, "order-1", "picked_up"))
    assert picked_up.status == 200
    assert picked_up.resp_body =~ "Handoff recorded."
    assert row(c, "order-1").phase == :accepted
    pickup_head = Log.head()
    assert receipt(picked_up, trip, "picked_up", code(c, "order-1", "picked_up")).status == 200
    assert row(c, "order-1").dispatch_phase == :in_transit
    assert Log.head() == pickup_head
    delivered = receipt(picked_up, trip, "delivered", code(c, "order-1", "delivered"))
    assert delivered.status == 200
    assert delivered.resp_body =~ "Handoff recorded."
    assert trip!(c, "order-1").status == :ACTIVE
    assert {:ok, nil} = poll()
    assert trip!(c, "order-1").status == :COMPLETED

    assert_exact_fulfillment(c, "order-1", accepted_quote)
    assert Log.head().global_seq == before + 3
    head = Log.head()

    # A retry has a fresh signed envelope, but the same admitted command/proof.
    assert receipt(delivered, trip, "delivered", code(c, "order-1", "delivered")).status == 200
    assert {:ok, nil} = poll()
    assert Log.head() == head
    assert {:ok, [_]} = loads(c)
    assert length(assignments(c)) == 1
    assert :ok = Log.verify_chains()
  end

  test "busy courier leaves the second canonical order queued and later reuses that exact order",
       c do
    quote1 = order!(c, "order-1")
    quote2 = order!(c, "order-2")
    assert {:ok, nil} = poll()
    first = trip!(c, "order-1")
    assert first.status == :ACTIVE
    assert {:ok, [_]} = loads(c)
    assert row(c, "order-2").dispatch_phase == :requested
    assert row(c, "order-2").accepted_quote == quote2

    page = login(c.user, c.courier_role)
    page = receipt(page, first, "picked_up", code(c, "order-1", "picked_up"))
    assert page.status == 200
    page = receipt(page, first, "delivered", code(c, "order-1", "delivered"))
    assert page.status == 200
    assert {:ok, nil} = poll()
    assert trip!(c, "order-1").status == :COMPLETED
    second = trip!(c, "order-2")
    assert second.status == :ACTIVE
    refute second.id == first.id
    assert length(assignments(c)) == 2
    assert row(c, "order-2").scope == scope(c, "order-2")
    assert row(c, "order-2").accepted_quote == quote2
    assert row(c, "order-1").accepted_quote == quote1

    head = Log.head()
    assert receipt(page, second, "picked_up", code(c, "order-1", "picked_up")).status == 422
    assert Log.head() == head
    assert row(c, "order-2").dispatch_phase == :accepted
  end

  test "wrong courier, wrong phase/code and revoked grant cannot append custody evidence", c do
    order!(c, "order-1")
    assert {:ok, nil} = poll()
    trip = trip!(c, "order-1")
    %{user: stranger_user, participant: stranger} = Fixtures.person(c.tenant, c.carrier)

    stranger_role =
      Fixtures.assignment(c.tenant, c.carrier, stranger, "DRIVER",
        definition: c.courier_role.role_definition
      )

    stranger_page = login(stranger_user, stranger_role)
    refute stranger_page.resp_body =~ trip.id
    head = Log.head()

    assert receipt(stranger_page, trip, "picked_up", code(c, "order-1", "picked_up")).status ==
             422

    assert Log.head() == head
    page = login(c.user, c.courier_role)
    assert receipt(page, trip, "picked_up", code(c, "another-order", "picked_up")).status == 422
    assert receipt(page, trip, "delivered", code(c, "order-1", "delivered")).status == 422
    assert Log.head() == head

    {:ok, stale_actor} = Actor.from_assignment(c.courier_role)
    revoke!(c.courier_role, c.tenant)

    assert {:error, :receipt_not_accepted} =
             RestaurantReceipts.submit(stale_actor, %{
               "assignment_id" => trip.id,
               "phase" => "picked_up",
               "handoff_token" => code(c, "order-1", "picked_up")
             })

    assert receipt(page, trip, "picked_up", code(c, "order-1", "picked_up")).status == 302
    assert Log.head() == head
    assert row(c, "order-1").dispatch_phase == :accepted
    assert trip!(c, "order-1").status == :ACTIVE
  end

  test "service revocation prevents a worker from assigning queued work", c do
    order!(c, "order-1")
    head = Log.head()
    revoke!(c.service, c.tenant)
    assert {:error, :unauthorized_service} = poll()
    assert {:ok, []} = loads(c)
    assert assignments(c) == []
    assert row(c, "order-1").dispatch_phase == :requested
    assert Log.head() == head
  end

  test "cancellation clears a planned trip, while accepted custody fences commercial cancellation",
       c do
    quote = order!(c, "order-1")

    assert {:ok, {_load, planned}} =
             RestaurantAutomation.prepare(c.service_actor, c.config, "order-1")

    assert planned.status == :PLANNED
    assert {:ok, _} = business(c, "order-1", "cancel", 5, %{"evidence_ref" => "buyer-cancel"})
    head = Log.head()
    assert {:ok, nil} = poll()
    assert trip!(c, "order-1").status == :CANCELLED
    assert row(c, "order-1").phase == :cancelled
    assert row(c, "order-1").accepted_quote == quote
    assert Log.head() == head

    assert {:error, {:restaurant_refused, 422, body}} =
             RestaurantDelivery.publish_automated(accept_command(planned, "order-1"), c.config)

    assert Jason.decode!(body) == %{"error" => "delivery_order_not_ready"}
    assert {:ok, nil} = poll()
    assert Log.head() == head

    order!(c, "order-2")
    assert {:ok, nil} = poll()
    assert trip!(c, "order-2").status == :ACTIVE
    head = Log.head()

    assert {:error, {:reject, 0, :dispatch_custody_reconciliation_required}} =
             business(c, "order-2", "cancel", 5, %{"evidence_ref" => "too-late-cancel"})

    assert row(c, "order-2").phase == :accepted
    assert Log.head() == head
  end

  test "worker and canonical appender restarts recover accepted, in-transit and delivered state",
       c do
    quote = order!(c, "order-1")

    assert {:ok, {_load, planned}} =
             RestaurantAutomation.prepare(c.service_actor, c.config, "order-1")

    # Simulate the process boundary after remote admission, before activation.
    assert {:ok, _} =
             RestaurantDelivery.publish_automated(accept_command(planned, "order-1"), c.config)

    assert trip!(c, "order-1").status == :PLANNED
    head = Log.head()
    run_worker_until(fn -> trip!(c, "order-1").status == :ACTIVE end)
    assert Log.head() == head
    trip = trip!(c, "order-1")
    assert trip.id == planned.id

    page = login(c.user, c.courier_role)
    page = receipt(page, trip, "picked_up", code(c, "order-1", "picked_up"))
    assert page.status == 200
    assert row(c, "order-1").dispatch_phase == :in_transit
    in_transit = Procurement.state(Log.gate())
    head = Log.head()
    assert :ok = restart_log()
    assert Procurement.state(Log.gate()) == in_transit
    run_worker_until(fn -> trip!(c, "order-1").status == :ACTIVE end)
    assert Log.head() == head
    assert length(assignments(c)) == 1

    page = receipt(page, trip, "delivered", code(c, "order-1", "delivered"))
    assert page.status == 200
    head = Log.head()
    assert :ok = restart_log()
    run_worker_until(fn -> trip!(c, "order-1").status == :COMPLETED end)
    assert Log.head() == head
    assert trip!(c, "order-1").id == planned.id
    assert_exact_fulfillment(c, "order-1", quote)
    assert :ok = Log.verify_chains()
  end

  test "signed work replay and multi-signer steps are refused before a valid worker succeeds",
       c do
    quote = order!(c, "order-1")
    signed_work = RestaurantDeliveryWork.sign(c.config, "", c.signer.seed)
    assert http_post(c.config.url <> "/work", signed_work).status == 200
    head = Log.head()
    assert http_post(c.config.url <> "/work", signed_work).status == 403

    wrong_source =
      RestaurantDeliveryWork.sign(%{c.config | source: :restaurant}, "", c.signer.seed)

    assert http_post(c.config.url <> "/work", wrong_source).status == 403

    extra = new_member("procurement_dispatch", "extra-unenrolled")
    fake_trip = %{id: Ash.UUID.generate(), load_id: Ash.UUID.generate()}

    payload =
      accept_command(fake_trip, "order-1")
      |> Map.merge(%{
        "cooperative_id" => c.context.cooperative_id,
        "tenant_id" => c.tenant,
        "automated" => true
      })

    event =
      multi_signed_event([c.signer, extra], "ProcurementDispatchStepV1", payload,
        chapter_id: c.context.chapter_id
      )

    assert :ok = Envelope.verify(event)
    {:ok, bytes} = Canonical.encode(Envelope.full_record_term(event))
    appender = GenServer.whereis(Log.server())

    assert http_post(c.config.url, %{"record" => Base.url_encode64(bytes, padding: false)}).status ==
             403

    assert GenServer.whereis(Log.server()) == appender
    assert Log.head() == head
    assert {:ok, nil} = poll()
    assert trip!(c, "order-1").status == :ACTIVE
    assert row(c, "order-1").accepted_quote == quote
    assert :ok = Log.verify_chains()
  end

  defp tick do
    now = System.system_time(:millisecond)
    ProcurementTestClock.set(now)
    now
  end

  defp append!(signer, context, type, payload) do
    tick()

    event =
      signed_event(signer, type, payload,
        chapter_id: context.chapter_id,
        timestamp_ms: div(Procurement.clock_ms(), 1_000) * 1_000
      )

    assert {:ok, [_]} = Log.append(event)
  end

  defp order!(c, id) do
    now = tick()

    commands = [
      {"request",
       %{
         "buyer_business_id" => "buyer",
         "description" => "Bulk packaging",
         "quantity" => 4,
         "currency" => "USD",
         "needed_by_ms" => now + 86_400_000,
         "consent_ref" => "buyer-consent-" <> id
       }},
      {"qualify", %{"evidence_ref" => "qualified-" <> id}},
      {"quote",
       %{
         "quote_id" => "quote-" <> id,
         "merchant_business_id" => "supplier",
         "revision" => 1,
         "total_minor" => 12000,
         "currency" => "USD",
         "expires_at_ms" => now + 600_000,
         "source_ref" => "supplier-quote-" <> id
       }},
      {"accept",
       %{
         "quote_id" => "quote-" <> id,
         "revision" => 1,
         "buyer_business_id" => "buyer",
         "evidence_ref" => "buyer-acceptance-" <> id
       }}
    ]

    for {{action, attrs}, version} <- Enum.with_index(commands) do
      assert {:ok, _} = business(c, id, action, version, attrs)
    end

    quote = row(c, id).accepted_quote
    tick()
    assert :ok = Handoff.request(c.context, id, 4)
    quote
  end

  defp business(c, id, action, version, attrs) do
    tick()

    Procurement.submit(c.context, id, %{
      "id" => "#{id}-#{action}-#{version}",
      "action" => action,
      "expected_version" => version,
      "attrs" => attrs
    })
  end

  defp scope(c, id), do: {c.context.chapter_id, c.context.cooperative_id, id}
  defp code(c, id, phase), do: Handoff.code(c.context, id, phase)

  defp reference(c, id),
    do:
      RestaurantDelivery.load_reference(
        c.context.chapter_id,
        c.context.cooperative_id,
        id,
        :procurement
      )

  defp row(c, id) do
    tick()
    assert {:ok, snapshot} = Procurement.snapshot(c.context)
    Enum.find(snapshot.requests, &(&1.scope == scope(c, id)))
  end

  defp poll do
    tick()
    RestaurantAutomation.poll("", :procurement)
  end

  defp loads(c), do: Ash.read(Load, tenant: c.tenant, authorize?: false)
  defp assignments(c), do: Ash.read!(Assignment, tenant: c.tenant, authorize?: false)

  defp trip!(c, id) do
    assert {:ok, loads} = loads(c)
    load = Enum.find(loads, &(&1.external_reference == reference(c, id)))
    assert load
    assert [trip] = Enum.filter(assignments(c), &(&1.load_id == load.id))
    trip
  end

  defp assert_exact_fulfillment(c, id, quote) do
    row = row(c, id)
    assert row.scope == scope(c, id)
    assert row.phase == :fulfilled
    assert row.version == 6
    assert row.accepted_quote == quote
    assert row.payment_evidence == []
    assert map_size(Procurement.state(Log.gate()).requests) == 1
    assert {:ok, events} = Log.read_all()
    steps = Enum.filter(events, &(&1.type == "ProcurementDispatchStepV1"))
    assert Enum.map(steps, & &1.payload["op"]) == ["accept", "picked_up", "delivered"]
    assert Enum.all?(steps, &(&1.payload["order_id"] == id))
    trip = trip!(c, id)

    assert Enum.all?(steps, fn step ->
             step.payload["assignment_id"] == trip.id and
               step.payload["load_id"] == trip.load_id and
               step.payload["tenant_id"] == c.tenant and
               step.payload["cooperative_id"] == c.context.cooperative_id
           end)

    delivered = List.last(steps)
    assert row.outcome_ref == "dispatch:" <> delivered.payload["proof_id"]

    assert delivered.payload["proof_digest"] ==
             Base.encode16(:crypto.hash(:sha256, code(c, id, "delivered")), case: :lower)

    refute Enum.any?(events, &String.starts_with?(&1.type, "Restaurant"))

    refute Enum.any?(
             events,
             &(&1.type in ["NettingExecuted", "PaymentRecorded", "SettlementExecuted"])
           )

    assert Enum.all?(
             events,
             &(&1.type != "ProcurementCommandAdmittedV1" or
                 &1.payload["command"]["action"] != "payment_evidence")
           )
  end

  defp service_role(tenant) do
    definition = Fixtures.role_definition(tenant, "DISPATCHER")

    RoleAssignment
    |> Ash.Changeset.for_create(:grant, %{
      tenant_id: tenant,
      principal_type: :SERVICE,
      principal_id: Ash.UUID.generate(),
      organization_id: tenant,
      role_definition_id: definition.id,
      scope_type: :ORGANIZATION,
      starts_at: DateTime.add(DateTime.utc_now(), -60)
    })
    |> Ash.create!(authorize?: false, tenant: tenant)
    |> Ash.load!([:role_definition], authorize?: false, tenant: tenant)
  end

  defp revoke!(role, tenant) do
    role
    |> Ash.Changeset.for_update(:revoke, %{})
    |> Ash.update!(authorize?: false, tenant: tenant)
  end

  defp accept_command(trip, id),
    do: %{
      "op" => "accept",
      "order_id" => id,
      "load_id" => trip.load_id,
      "assignment_id" => trip.id,
      "command_id" => "accept-" <> Base.url_encode64(:crypto.hash(:sha256, id), padding: false),
      "expected_version" => 0
    }

  defp http_post(url, body) do
    tick()

    assert {:ok, response} =
             Finch.request(
               Finch.build(
                 :post,
                 url,
                 [{"content-type", "application/json"}],
                 Jason.encode!(body)
               ),
               Dispatch.Finch
             )

    response
  end

  defp portal(method, path, params \\ %{}, previous \\ nil) do
    Plug.CSRFProtection.delete_csrf_token()
    request = conn(method, path, params)

    request = %{
      request
      | secret_key_base: Application.fetch_env!(:dispatch, DispatchWeb.Endpoint)[:secret_key_base]
    }

    request = if previous, do: recycle_cookies(request, previous), else: request

    request
    |> Plug.RequestId.call(Plug.RequestId.init(assign_as: :correlation_id))
    |> Plug.Session.call(@session)
    |> fetch_session()
    |> DispatchWeb.Router.call(DispatchWeb.Router.init([]))
  end

  defp csrf(page),
    do: Regex.run(~r/name="_csrf_token" value="([^"]+)"/, page.resp_body) |> Enum.at(1)

  defp login(user, role) do
    form = portal(:get, "/login")

    signed_in =
      portal(
        :post,
        "/session",
        %{"_csrf_token" => csrf(form), "token" => PortalIdentity.token_for(user.oidc_subject)},
        form
      )

    assert signed_in.status == 302
    choose = portal(:get, "/select-role", %{}, signed_in)
    assert choose.status == 200

    selected =
      portal(
        :post,
        "/select-role",
        %{"_csrf_token" => csrf(choose), "role_assignment_id" => role.id},
        choose
      )

    assert selected.status == 302
    page = portal(:get, @portal_path, %{}, selected)
    assert page.status == 200
    page
  end

  defp receipt(page, trip, phase, code) do
    tick()

    portal(
      :post,
      @portal_path,
      %{
        "_csrf_token" => csrf(page),
        "assignment_id" => trip.id,
        "phase" => phase,
        "handoff_token" => code
      },
      page
    )
  end

  defp run_worker_until(predicate) do
    tick()
    {:ok, worker} = RestaurantAutomation.start_link(:procurement)

    try do
      # The explicit poll and system query come from the same sender. This
      # barrier observes a completed real reconciliation even when the durable
      # trip already has the desired state (the in-transit restart case).
      send(worker, :poll)
      :sys.get_state(worker)
      await(predicate, 250)
    after
      GenServer.stop(worker)
    end
  end

  defp await(predicate, remaining) when remaining > 0 do
    if predicate.() do
      :ok
    else
      Process.sleep(20)
      await(predicate, remaining - 1)
    end
  end

  defp await(predicate, 0),
    do: assert(predicate.(), "worker did not reconcile persisted delivery state")
end
