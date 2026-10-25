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
      if Process.alive?(s), do: GenServer.stop(s)
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

    for path <- ["/commands", "/ledger", "/inventory/reserve", "/payments", "/publish"] do
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
