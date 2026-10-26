defmodule FederationService.RouterTest do
  use ExUnit.Case, async: true
  import FederationService.TestHelpers
  alias FederationService.{Router, Store}

  setup do
    dir = temp()
    {:ok, s} = Store.start_link(directory: dir)

    config =
      FederationService.config!(
        actor: "https://alpha.example/actors/shop",
        store: s,
        private_key: key()
      )

    on_exit(fn ->
      stop_store(s)
      File.rm_rf!(dir)
    end)

    %{config: config, s: s, dir: dir}
  end

  defp request(config, method, path, body \\ "") do
    Plug.Test.conn(method, path, body)
    |> Map.put(:host, "alpha.example")
    |> Map.update!(:req_headers, &[{"host", "alpha.example"} | &1])
    |> Router.call(config)
  end

  test "WebFinger is opt-in, exact actor/handle-bound and never creates identity grants", c do
    config = %{c.config | handle: "shop"}
    actor = config.actor
    acct = "acct:shop@alpha.example"

    for resource <- [acct, actor] do
      response = request(config, :get, "/.well-known/webfinger?resource=" <> URI.encode_www_form(resource))
      assert response.status == 200
      assert Plug.Conn.get_resp_header(response, "content-type") == ["application/jrd+json; charset=utf-8"]

      doc = Jason.decode!(response.resp_body)
      assert doc == %{
               "subject" => acct,
               "aliases" => [actor],
               "links" => [
                 %{"rel" => "self", "type" => "application/activity+json", "href" => actor}
               ]
             }
    end

    actor_doc = request(config, :get, "/actors/shop").resp_body |> Jason.decode!()
    assert actor_doc["preferredUsername"] == "shop"

    refute Map.has_key?(Store.call(c.s, :snapshot), :principal_grants)
    assert request(c.config, :get, "/.well-known/webfinger?resource=acct%3Ashop%40alpha.example").status == 404

    for query <- [
          "resource=acct%3Aother%40alpha.example",
          "resource=acct%3Ashop%40evil.example",
          "resource=https%3A%2F%2Fevil.example%2Factors%2Fshop",
          "resource=acct%3Ashop%40alpha.example&resource=acct%3Aother%40alpha.example",
          "resource=acct%3Ashop%40alpha.example&admin=true",
          "subject=acct%3Ashop%40alpha.example"
        ] do
      refute request(config, :get, "/.well-known/webfinger?" <> query).status == 200
    end

    assert request(config, :post, "/.well-known/webfinger", "{}").status == 404
  end

  test "actor and bounded outbox pages persist public events even without destinations", c do
    for revision <- 0..20 do
      assert {:ok, :published} =
               FederationService.publish(
                 c.config,
                 "event-#{revision}",
                 metadata(c.config.actor, revision),
                 if(revision == 0, do: :create, else: :update)
               )
    end

    doc = request(c.config, :get, "/actors/shop").resp_body |> Jason.decode!()
    assert doc["publicKey"]["owner"] == c.config.actor
    outbox = request(c.config, :get, "/actors/shop/outbox").resp_body |> Jason.decode!()
    assert outbox["type"] == "OrderedCollection" and outbox["totalItems"] == 21
    page0 = request(c.config, :get, "/actors/shop/outbox/page/0").resp_body |> Jason.decode!()
    assert length(page0["orderedItems"]) == 20 and page0["next"] != nil
    page1 = request(c.config, :get, "/actors/shop/outbox/page/1").resp_body |> Jason.decode!()
    assert length(page1["orderedItems"]) == 1 and page1["next"] == nil
    assert request(c.config, :get, "/actors/shop/outbox/page/-1").status == 404
  end

  test "combined market searches source-attributed untrusted text without executing markup", c do
    m = metadata(c.config.actor, 0, %{title: "<script>bad()</script>", summary: "Part"})
    FederationService.publish(c.config, "event", m)
    html = request(c.config, :get, "/market").resp_body
    assert html =~ "&lt;script&gt;" and html =~ "alpha.example"
    refute html =~ "<script>"

    assert request(c.config, :get, "/market.json?q=missing").resp_body |> Jason.decode!() == %{
             "listings" => []
           }

    assert length(
             Jason.decode!(request(c.config, :get, "/market.json?q=part").resp_body)["listings"]
           ) == 1

    assert request(c.config, :get, "/market?q=x&admin=true").status == 400
    assert request(c.config, :get, "/actors/shop?key=other").status == 400
  end

  test "no network endpoint admits business commands; body and Host checks precede authentication",
       c do
    initial = Store.call(c.s, :snapshot)

    for path <- [
          "/commands",
          "/ledger",
          "/inventory/reserve",
          "/payments",
          "/publish",
          "/redeliver",
          "/resync"
        ] do
      assert request(c.config, :post, path, ~s({"command":"approve","signed":true})).status == 404
    end

    assert request(c.config, :post, "/actors/shop/inbox", String.duplicate("x", 65_537)).status ==
             413

    assert request(c.config, :post, "/actors/shop/inbox", "{}").status == 401

    assert (Plug.Test.conn(:get, "/market")
            |> Map.put(:host, "evil.example")
            |> Map.update!(:req_headers, &[{"host", "evil.example"} | &1])
            |> Router.call(c.config)).status == 400

    assert Store.call(c.s, :snapshot) == initial
  end

  test "second writer is refused while first owns directory", c do
    assert {:error, :directory_in_use} = GenServer.start(Store, directory: c.dir)
  end
end
