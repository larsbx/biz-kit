defmodule ProcurementHost.HTTPTest do
  use CoopSubstrate.LogCase, async: false
  import Plug.Test
  alias CoopSubstrate.{Log, Procurement, ProcurementFixture, ProcurementTestClock, RestaurantDeliveryWork}
  alias ProcurementHost.{HTML, Web}
  @token String.duplicate("x", 48)

  setup do
    f = ProcurementFixture.setup()
    settings = Map.merge(f.context, %{login_digest: :crypto.hash(:sha256, @token),
      secret_key_base: String.duplicate("s", 64)})
    Application.put_env(:procurement_host, :settings, settings)
    {:ok, f: f}
  end

  defp request(method, path, params \\ %{}, previous \\ nil) do
    # Each request gets a fresh process-local CSRF state, like the real server.
    Plug.CSRFProtection.delete_csrf_token()
    c = conn(method, path, params) |> Map.put(:scheme, :https)
    c = if previous, do: recycle_cookies(c, previous), else: c
    Web.call(c, Web.init([]))
  end
  defp csrf(c), do: Regex.run(~r/name="_csrf_token" value="([^"]+)"/, c.resp_body) |> Enum.at(1)
  defp login do
    form = request(:get, "/login")
    request(:post, "/login", %{"token" => @token, "_csrf_token" => csrf(form)}, form)
  end

  test "unauthenticated read is refused; token never appears in the page" do
    c = request(:get, "/requests")
    assert c.status == 303
    assert Plug.Conn.get_resp_header(c, "location") == ["/login"]
    form = request(:get, "/login")
    assert form.status == 200
    refute form.resp_body =~ @token
    assert Plug.Conn.get_resp_header(form, "cache-control") == ["no-store"]
  end

  test "actual form workflow reaches fulfillment and survives Log restart", %{f: f} do
    session = login()
    assert session.status == 303
    page = request(:get, "/requests", %{}, session)
    assert page.status == 200
    # HTTP forms, cookie session and CSRF, not a direct reducer call.
    commands = [
      {"request", 0, %{"buyer_business_id" => "buyer", "description" => "<script>alert(1)</script>",
        "quantity" => "4", "currency" => "USD", "needed_by_ms" => "2030-01-01T12:00", "consent_ref" => "consent"}},
      {"qualify", 1, %{"evidence_ref" => "qualified"}},
      {"quote", 2, %{"quote_id" => "q", "merchant_business_id" => "merchant", "revision" => "1",
        "total_minor" => "12000", "currency" => "USD", "expires_at_ms" => "2030-01-01T12:00", "source_ref" => "quote-source"}},
      {"accept", 3, %{"quote_id" => "q", "revision" => "1", "buyer_business_id" => "buyer", "evidence_ref" => "accepted"}},
      {"fulfill", 4, %{"evidence_ref" => "delivered"}}
    ]
    final = Enum.reduce(commands, page, fn {action, version, attrs}, previous ->
      params = Map.merge(attrs, %{"_csrf_token" => csrf(previous), "expected_version" => to_string(version),
        "command_id" => "http-#{version}"})
      result = request(:post, "/requests/http-request/" <> action, params, previous)
      assert result.status == 303
      detail = request(:get, "/requests/http-request", %{}, result)
      assert detail.status == 200
      refute detail.resp_body =~ "<script>"
      detail
    end)
    assert final.resp_body =~ "fulfilled"
    assert final.resp_body =~ "Frozen accepted quote"
    :ok = restart_log()
    assert request(:get, "/requests/http-request", %{}, final).resp_body =~ "fulfilled"
    assert {:ok, %{requests: [%{payment_evidence: []}]}} = Procurement.snapshot(f.context)
  end

  test "the accepted order exposes signed work through its existing coordinator page", %{f: f} do
    :ok = ProcurementFixture.quoted(f)
    assert {:ok, _} = ProcurementFixture.submit(f, "accept", 3, ProcurementFixture.acceptance())
    signer = new_member("procurement_dispatch", "dispatch")
    tenant = "11111111-1111-1111-1111-111111111111"
    route = ProcurementFixture.event(f, "ProcurementDispatchRouteV1", %{
      "cooperative_id" => "coop", "tenant_id" => tenant, "site" => "North dock",
      "key_id" => signer.signer.key_id, "pubkey" => {:bytes, signer.signer.pubkey},
      "active" => true, "expected_version" => 0
    })
    assert {:ok, [_]} = Log.append(route)

    detail = request(:get, "/requests/request-1", %{}, login())
    assert detail.resp_body =~ "Queue Dispatch handoff"
    assert request(:post, "/requests/request-1/dispatch",
      %{"_csrf_token" => csrf(detail), "expected_version" => "4"}, detail).status == 303

    scope = %{source: :procurement, chapter: f.context.chapter_id, merchant: "coop",
      tenant: tenant, key_id: signer.signer.key_id}

    signed = RestaurantDeliveryWork.sign(scope, "", signer.seed)
    response = work(signed)
    assert response.status == 200
    assert %{"jobs" => [%{"order_id" => "request-1", "site" => "North dock", "phase" => "requested"}]} =
      :json.decode(response.resp_body)
    assert work(signed).status == 403
    assert work(RestaurantDeliveryWork.sign(%{scope | source: :restaurant}, "", signer.seed)).status == 403
  end

  defp work(input) do
    c = conn(:post, "/api/procurement-dispatch/work", IO.iodata_to_binary(:json.encode(input)))
    c = Plug.Conn.put_req_header(c, "content-type", "application/json")
    Web.call(c, Web.init([]))
  end

  test "revocation denies an already authenticated browser read and write", %{f: f} do
    session = login()
    page = request(:get, "/requests", %{}, session)
    {:ok, [_]} = Log.append(ProcurementFixture.grant(f, false, 1))
    assert request(:get, "/operations", %{}, page).status == 303
    result = request(:post, "/requests/r/request", %{"_csrf_token" => csrf(page)}, page)
    assert result.status == 303
    assert Procurement.state(Log.gate()).requests == %{}
  end

  test "CSRF failure occurs before mutation and session expiry denies access", %{f: f} do
    page = request(:get, "/requests", %{}, login())
    head = Log.head()
    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      request(:post, "/requests/r/request", %{}, page)
    end
    assert Log.head() == head
    ProcurementTestClock.set(f.now + 14_400_001)
    assert request(:get, "/requests", %{}, page).status == 303
  end

  test "HTML escape and closed form conversion" do
    assert HTML.escape("<script>\"&") == "&lt;script&gt;&quot;&amp;"
    assert {:error, _} = HTML.attributes("made_up", %{})
    assert {:error, _} = HTML.attributes("quote", %{"total_minor" => "12junk"})
  end
end
