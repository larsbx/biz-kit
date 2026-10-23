defmodule DispatchWeb.LocationControllerTest do
  @moduledoc """
  Consented location sharing over `/v1` (Sections 24.2, 25.3), and scenario 2's
  server half: a sample appears with its accuracy and age on the operations
  page, and nothing of it reaches a reader without the relationship.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Dispatch.Support.Fixtures
  alias Dispatch.Support.PortalIdentity, as: StaticVerifier
  alias DispatchWeb.Plugs.PortalSession

  @moduletag :integration

  @opts DispatchWeb.Router.init([])

  @session Plug.Session.init(
             store: :cookie,
             key: "_dispatch_session",
             signing_salt: "5xJq0pQe",
             encryption_salt: "Nn4vT2kA"
           )

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)
    :ok = Dispatch.Support.PortalIdentity.setup()

    org = Fixtures.carrier()
    tenant = org.id
    %{user: user, participant: driver} = Fixtures.person(tenant, org)
    Fixtures.assignment(tenant, org, driver, "DRIVER")
    {device, seed} = Fixtures.keyed_device(tenant, driver)
    trip = Fixtures.assignment_record(tenant, org, driver)

    %{
      org: org,
      tenant: tenant,
      driver: driver,
      device: device,
      seed: seed,
      trip: trip,
      token: StaticVerifier.token_for(user.oidc_subject)
    }
  end

  defp post(path, body, token, headers \\ []) do
    :post
    |> conn(path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> then(&Enum.reduce(headers, &1, fn {k, v}, c -> put_req_header(c, k, v) end))
    |> DispatchWeb.Plugs.LocationBatchParser.call([])
    |> then(fn conn ->
      if conn.halted do
        conn
      else
        conn
        |> Plug.Parsers.call(
          Plug.Parsers.init(parsers: [:json], pass: ["*/*"], json_decoder: Jason)
        )
        |> DispatchWeb.Router.call(@opts)
      end
    end)
  end

  defp page(path, user, assignment) do
    :get
    |> conn(path)
    |> put_in(
      [Access.key(:secret_key_base)],
      Application.get_env(:dispatch, DispatchWeb.Endpoint)[:secret_key_base]
    )
    |> Plug.Session.call(@session)
    |> fetch_session()
    |> then(fn conn ->
      [
        {PortalSession.subject_key(), user.oidc_subject},
        {PortalSession.assignment_key(), assignment.id}
      ]
      |> Dispatch.Support.PortalIdentity.bind()
      |> Enum.reduce(conn, fn {key, value}, acc -> put_session(acc, key, value) end)
    end)
    |> DispatchWeb.Router.call(@opts)
  end

  defp consent!(ctx) do
    conn = post("/v1/me/location-consents", %{"assignment_id" => ctx.trip.id}, ctx.token)
    assert conn.status == 201
    Jason.decode!(conn.resp_body)
  end

  defp sample(ctx, grant_id, overrides \\ %{}) do
    %{
      "sample_id" => Ash.UUID.generate(),
      "assignment_id" => ctx.trip.id,
      "lat_e7" => 515_074_000,
      "lng_e7" => -1_278_000,
      "accuracy_cm" => 1_240,
      "provider" => "fused",
      "is_mock" => false,
      "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "device_id" => ctx.device.id,
      "device_sequence" => System.unique_integer([:positive]),
      "consent_grant_id" => grant_id
    }
    |> Map.merge(overrides)
    |> Fixtures.signed_sample(ctx.seed)
  end

  defp results(conn), do: conn.resp_body |> Jason.decode!() |> Map.fetch!("results")

  test "consent, a signed batch, and per-sample results under 207", ctx do
    %{"consent_grant_id" => grant, "assignment_id" => trip, "revoked_at" => nil} = consent!(ctx)
    assert trip == ctx.trip.id

    good = sample(ctx, grant)
    bad = Map.put(sample(ctx, grant), "lat_e7", 0)

    conn = post("/v1/me/location-samples:batch", %{"samples" => [good, bad]}, ctx.token)

    assert conn.status == 207

    assert results(conn) == [
             %{"sample_id" => good["sample_id"], "result" => "ACCEPTED", "code" => nil},
             %{
               "sample_id" => bad["sample_id"],
               "result" => "REJECTED",
               "code" => "DEVICE_SIGNATURE_INVALID"
             }
           ]
  end

  test "the DRIVER route is the same function; only the custom method is a route", ctx do
    %{"consent_grant_id" => grant} = consent!(ctx)
    body = %{"samples" => [sample(ctx, grant)]}

    assert post("/v1/driver/location-samples:batch", body, ctx.token).status == 207
    assert post("/v1/me/location-samplesXYZ", body, ctx.token).status == 404
  end

  test "revoking ends sharing for what is acquired afterwards", ctx do
    %{"consent_grant_id" => grant} = consent!(ctx)
    earlier = sample(ctx, grant)
    Process.sleep(5)

    revoked = post("/v1/me/location-consents/#{grant}/revoke", %{}, ctx.token)
    assert revoked.status == 200
    assert Jason.decode!(revoked.resp_body)["revoked_at"]

    later = sample(ctx, grant)
    conn = post("/v1/me/location-samples:batch", %{"samples" => [earlier, later]}, ctx.token)

    assert Enum.map(results(conn), & &1["code"]) == [nil, "REJECTED_CONSENT"]
  end

  test "oversized batches are refused whole", ctx do
    %{"consent_grant_id" => grant} = consent!(ctx)
    many = for _ <- 1..101, do: sample(ctx, grant)

    assert post("/v1/me/location-samples:batch", %{"samples" => many}, ctx.token).status == 413
  end

  # A chunked upload declares no length; the cap is on what arrived.
  test "the 256 KiB cap holds without a Content-Length", ctx do
    %{"consent_grant_id" => grant} = consent!(ctx)
    padded = Map.put(sample(ctx, grant), "padding", String.duplicate("x", 300_000))
    conn = post("/v1/me/location-samples:batch", %{"samples" => [padded]}, ctx.token)

    assert conn.status == 413
    assert Jason.decode!(conn.resp_body)["code"] == "BATCH_TOO_LARGE"
  end

  test "the endpoint enforces raw bytes before its general parser", _ctx do
    for path <- ["/v1/me/location-samples:batch", "/v1/driver/location-samples%3Abatch/"] do
      conn =
        :post
        |> conn(path, String.duplicate(" ", 300_000) <> ~s({"samples":[]}))
        |> put_req_header("content-type", "application/json")
        |> delete_req_header("content-length")
        |> DispatchWeb.Endpoint.call(DispatchWeb.Endpoint.init([]))

      assert conn.status == 413
      assert Jason.decode!(conn.resp_body)["code"] == "BATCH_TOO_LARGE"
    end
  end

  test "someone else's trip is not found", ctx do
    %{participant: other} = Fixtures.person(ctx.tenant, ctx.org)
    theirs = Fixtures.assignment_record(ctx.tenant, ctx.org, other)

    assert post("/v1/me/location-consents", %{"assignment_id" => theirs.id}, ctx.token).status ==
             404
  end

  describe "scenario 2: the sample on the operations page" do
    setup ctx do
      %{"consent_grant_id" => grant} = consent!(ctx)
      body = sample(ctx, grant, %{"accuracy_cm" => 1_240})

      assert post("/v1/me/location-samples:batch", %{"samples" => [body]}, ctx.token).status ==
               207

      :ok
    end

    test "a dispatcher sees when it was reported and how accurate, not where", ctx do
      %{user: desk_user, participant: desk} = Fixtures.person(ctx.tenant, ctx.org)
      dispatcher = Fixtures.assignment(ctx.tenant, ctx.org, desk, "DISPATCHER")

      conn = page("/operations/participants/#{ctx.driver.id}", desk_user, dispatcher)

      assert conn.status == 200
      assert conn.resp_body =~ "Last reported"
      assert conn.resp_body =~ ~s(data-source="OBSERVED")
      assert conn.resp_body =~ "±12 m"
      refute conn.resp_body =~ "51.5074"
      refute conn.resp_body =~ "-0.1278"
    end

    test "a broker without the relationship gets nothing at all", ctx do
      broker_org = Fixtures.organization(ctx.tenant, :BROKER)
      %{user: broker_user, participant: broker} = Fixtures.person(ctx.tenant, broker_org)
      load = Fixtures.load(ctx.tenant, ctx.org)

      assignment =
        Fixtures.assignment(ctx.tenant, broker_org, broker, "BROKER", scope_id: load.id)

      conn = page("/operations/participants/#{ctx.driver.id}", broker_user, assignment)

      assert conn.status == 404
      refute conn.resp_body =~ "Last reported"
    end
  end

  describe "GET /v1/me/location-demand" do
    defp demand(token) do
      :get
      |> conn("/v1/me/location-demand")
      |> put_req_header("accept", "text/event-stream")
      |> put_req_header("authorization", "Bearer " <> token)
      |> DispatchWeb.Router.call(@opts)
    end

    test "an EventSource's Accept reaches it, and without consent it is a 404", ctx do
      conn = demand(ctx.token)
      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["code"] == "NO_ACTIVE_CONSENT"
    end

    test "it needs a signed-in caller", _ctx do
      assert demand("not-a-token").status == 401
    end
  end
end
