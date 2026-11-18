defmodule RestaurantHost.DeviceGrantsTest do
  @moduledoc """
  `mix restaurant.grant` against the host over real HTTP: the administrator's
  governance key, held on their machine, signs exactly the grant shown, and
  only then do the device's orders and steps reach the ledger.
  """
  use ExUnit.Case, async: false

  alias CoopSubstrate.{Canonical, Crypto, Log}
  alias CoopSubstrate.Harness.Ops
  alias RestaurantHost.{DeviceGrants, Enrollment, Management, Orders, Restaurant, World}

  @port 4073
  @url "http://127.0.0.1:#{@port}"

  setup do
    dir = Path.join(System.tmp_dir!(), "rh-keys-#{System.unique_integer([:positive])}")
    previous = System.get_env("HARNESS_KEYS_DIR")
    System.put_env("HARNESS_KEYS_DIR", dir)

    on_exit(fn ->
      File.rm_rf!(dir)

      if previous,
        do: System.put_env("HARNESS_KEYS_DIR", previous),
        else: System.delete_env("HARNESS_KEYS_DIR")
    end)

    {:ok, _} = Ops.gen_key("governance")
    {:ok, gov} = Ops.load_signer("governance")

    start_supervised!(
      {Bandit, plug: RestaurantHost.Web.Endpoint, ip: {127, 0, 0, 1}, port: @port}
    )

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    {:ok, World.build(grant: false, governance: gov) |> Map.put(:gov, gov)}
  end

  defp grant!(device) do
    r = Restaurant.current()

    Mix.Tasks.Restaurant.Grant.run([
      device,
      "--chapter",
      r.chapter,
      "--merchant",
      r.merchant,
      "--server",
      @url,
      "--yes"
    ])
  end

  test "an ungranted device is refused; once granted by the tool it acts", %{restaurant: r} do
    assert Orders.place(r, %{"margherita" => 1}, "Ada", "key-1") == {:error, :forbidden}

    grant!("storefront")
    assert_received {:mix_shell, :info, ["granted: event " <> _]}
    assert {:ok, id} = Orders.place(r, %{"margherita" => 1}, "Ada", "key-1")
    assert Orders.step(r, "board-1", id, :accept, 0) == {:error, :forbidden}

    grant!("board-1")
    assert Orders.step(r, "board-1", id, :accept, 0) == :ok
  end

  test "the tool shows the grant before signing and refuses unknown devices" do
    grant!("board-1")
    assert_received {:mix_shell, :info, [shown]}
    assert shown =~ "device    board-1"
    assert shown =~ "acts as   staff: accept, start_preparing, mark_ready, complete, cancel"

    assert_raise Mix.Error, ~r/cannot grant: unexpected_proposal/, fn -> grant!("board-9") end
  end

  test "the administrator signs only exactly the grant shown", %{restaurant: r, gov: gov} do
    {:ok, d} = DeviceGrants.details(r, "board-1")
    shown = d |> DeviceGrants.json() |> Jason.encode!() |> Jason.decode!()

    {:ok, held} = DeviceGrants.prepare(r, "board-1", gov.key_id)

    {:ok, core} = Canonical.decode(held.signing_bytes)
    assert DeviceGrants.grants?(core, shown)

    for tampered <- [
          put_in(core, ["payload", "actions"], ["accept", "checkout"]),
          put_in(core, ["payload", "actor"], "admin"),
          put_in(core, ["payload", "pubkey"], {:bytes, :binary.copy(<<1>>, 32)}),
          put_in(core, ["payload", "merchant_id"], "other-shop"),
          Map.put(core, "chapter_id", "other-chapter"),
          Map.put(core, "type", "RoleKeyDeclared")
        ],
        do: refute(DeviceGrants.grants?(tampered, shown))
  end

  test "a signature by any other key is refused and nothing is appended", %{
    restaurant: r,
    gov: gov
  } do
    {:ok, held} = DeviceGrants.prepare(r, "board-1", gov.key_id)
    {_pub, rogue} = Crypto.generate_keypair()
    head = Log.head()

    assert {:error, _} =
             DeviceGrants.submit(r, "board-1", held.id, Crypto.sign(held.signing_bytes, rogue))

    assert Log.head() == head
    assert DeviceGrants.prepare(r, "board-1", "k-not-governance") |> elem(0) == :error
  end

  test "a held signature is bound to chapter, merchant, configured device and key and is spent once",
       %{restaurant: r, gov: gov} do
    {:ok, held} = DeviceGrants.prepare(r, "board-1", gov.key_id)
    sig = Crypto.sign(held.signing_bytes, gov.seed)
    head = Log.head()

    for other <- [
          %{r | chapter: "other-chapter"},
          %{r | merchant: "other-shop"},
          put_in(r.boards["board-1"].signer.key_id, "other-key")
        ] do
      assert {:error, :unknown_command} = DeviceGrants.submit(other, "board-1", held.id, sig)
    end

    assert {:error, :unknown_command} = DeviceGrants.submit(r, "storefront", held.id, sig)
    assert Log.head() == head
    assert {:ok, _} = DeviceGrants.submit(r, "board-1", held.id, sig)
    head = Log.head()
    assert {:error, :unknown_command} = DeviceGrants.submit(r, "board-1", held.id, sig)
    assert {:error, _} = DeviceGrants.prepare(r, "board-1", gov.key_id)
    assert Log.head() == head
  end

  test "expired holds and malformed signatures cannot append", %{restaurant: r, gov: gov} do
    {:ok, held} = DeviceGrants.prepare(r, "board-1", gov.key_id)
    sig = Crypto.sign(held.signing_bytes, gov.seed)
    head = Log.head()
    assert {:error, :bad_request} = DeviceGrants.submit(r, "board-1", held.id, <<1>>)

    owner =
      {:restaurant_device_grant, r.chapter, r.merchant, "board-1",
       r.boards["board-1"].signer.key_id, {:bytes, r.boards["board-1"].signer.pubkey}}

    assert {:error, :unknown_command} =
             CoopSubstrate.Commands.submit(owner, held.id, sig, held.expires_at + 1)

    assert Log.head() == head
  end

  test "the client refuses a proposal for another chapter or merchant", %{restaurant: r} do
    head = Log.head()

    assert {:error, :unexpected_proposal} =
             Enrollment.fetch(@url, "board-1", "elsewhere", r.merchant)

    assert {:error, :unexpected_proposal} =
             Enrollment.fetch(@url, "board-1", r.chapter, "elsewhere")

    assert Log.head() == head
  end

  test "declining review signs nothing", %{restaurant: r} do
    head = Log.head()
    io = %{info: fn _ -> :ok end, confirm: fn _ -> false end}
    args = ["board-1", "--chapter", r.chapter, "--merchant", r.merchant, "--server", @url]
    assert :ok = Enrollment.run(args, io)
    assert Log.head() == head
  end

  test "HTTP refuses payload overrides, cross-chapter requests and malformed signatures", %{
    restaurant: r,
    gov: gov
  } do
    head = Log.head()

    base = %{
      "chapter_id" => r.chapter,
      "merchant_id" => r.merchant,
      "governance_key_id" => gov.key_id
    }

    for body <- [
          Map.put(base, "actions", ["checkout"]),
          Map.put(base, "chapter_id", "elsewhere"),
          Map.put(base, "merchant_id", "elsewhere"),
          %{"governance_key_id" => []}
        ] do
      assert {422, _} = post("/api/device-grants/board-1", body)
    end

    assert {403, _} = post("/api/device-grants/board-1", base)

    assert {403, _} =
             post("/api/device-grants/board-1", Map.put(base, "governance_key_id", "unknown"))

    assert {422, _} = post("/api/device-grants/board-1/unknown", %{"signature" => []})
    assert {422, _} = post("/api/device-grants/board-1/unknown", %{"signature" => "%%%"})
    assert {422, _} = post("/api/device-grants/board-1/unknown", %{"signature" => "AQ"})
    assert Log.head() == head
  end

  test "the ledger rejects unauthorized, malformed and cross-chapter grants", %{
    restaurant: r,
    gov: gov
  } do
    {:ok, details} = DeviceGrants.details(r, "board-1")
    {pubkey, seed} = Crypto.generate_keypair()
    rogue = %{role: "governance", key_id: "rogue", pubkey: pubkey, seed: seed}
    head = Log.head()

    attempts = [
      {r.chapter, rogue, details.payload},
      {"other-chapter", gov, details.payload},
      {r.chapter, gov, Map.put(details.payload, "actions", ["unknown"])},
      {r.chapter, gov, Map.put(details.payload, "pubkey", {:bytes, <<1>>})},
      {r.chapter, gov, Map.put(details.payload, "seed", "forbidden")}
    ]

    # A payload the type schema refuses never becomes an envelope; every other
    # attempt is signed and refused by the Log.
    for {chapter, signer, payload} <- attempts do
      assert {:error, _} =
               with(
                 {:ok, env} <-
                   CoopSubstrate.Protocol.Envelope.new(%{
                     chapter_id: chapter,
                     type: details.type,
                     payload: payload,
                     signers: [Map.take(signer, [:role, :key_id, :pubkey])],
                     timestamp_ms: System.system_time(:millisecond)
                   }),
                 {:ok, env} <-
                   CoopSubstrate.Protocol.Envelope.sign(env, signer.key_id, signer.seed),
                 do: Log.append(env)
               )
    end

    assert Log.head() == head

    assert {:error, :unknown_governance_key} =
             DeviceGrants.prepare(%{r | chapter: "other-chapter"}, "board-1", gov.key_id)
  end

  test "preparation authenticates governance requests and refuses a replayed request nonce", %{
    restaurant: r,
    gov: gov
  } do
    path = "/api/device-grants/board-1"

    req = %{
      method: "POST",
      path: path,
      timestamp_ms: System.system_time(:millisecond),
      nonce: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
      key_id: gov.key_id
    }

    sig =
      req
      |> CoopSubstrate.Governance.Read.signing_bytes()
      |> Crypto.sign(gov.seed)
      |> Base.url_encode64(padding: false)

    header =
      ~s(CoopGovernance key="#{gov.key_id}", ts="#{req.timestamp_ms}", nonce="#{req.nonce}", sig="#{sig}")

    body = %{
      "chapter_id" => r.chapter,
      "merchant_id" => r.merchant,
      "governance_key_id" => gov.key_id
    }

    headers = [{~c"authorization", String.to_charlist(header)}]
    head = Log.head()
    assert {201, _} = post(path, body, headers)
    assert {403, _} = post(path, body, headers)

    malformed =
      String.replace(
        header,
        ~s(ts="#{req.timestamp_ms}"),
        ~s(ts="999999999999999999999999999999")
      )

    assert {403, _} = post(path, body, [{~c"authorization", String.to_charlist(malformed)}])
    assert Log.head() == head
  end

  test "a governance publication supersedes the bootstrap menu and revocation fences a paired board",
       %{restaurant: r, gov: gov} do
    grant!("storefront")
    grant!("board-1")

    menu = %{
      "merchant_id" => r.merchant,
      "currency" => "USD",
      "expected_revision" => 0,
      "items" => [
        %{
          "id" => "margherita",
          "name" => "Margherita",
          "sku" => "MARG",
          "price_minor" => 1250,
          "discount_minor" => 250
        }
      ]
    }

    assert {403, _} =
             post("/api/restaurant-management/publish-menu", %{
               "chapter_id" => r.chapter,
               "governance_key_id" => gov.key_id,
               "payload" => menu
             })

    assert {:ok, %{"event_id" => _}} =
             Management.approve(@url, r.chapter, "publish-menu", menu, gov)

    assert {:error, {422, _}} = Management.approve(@url, r.chapter, "publish-menu", menu, gov)

    assert Orders.place(r, %{"margherita" => 2}, "Ada", "stale") == {:error, :stale_menu}

    latest = Restaurant.published_menu(r)
    assert latest.menu_revision == 1
    assert Orders.price(latest, %{"pepperoni" => 1}) == {:error, :unknown_item}
    assert {:ok, order} = Orders.place(latest, %{"margherita" => 2}, "Ada", "fresh")

    assert %{subtotal: 2000, total: 2120, menu_revision: 1, lines: [%{"discount_minor" => 500}]} =
             Orders.get(r, order)

    assert {:ok, _} =
             Management.approve(
               @url,
               r.chapter,
               "publish-menu",
               %{menu | "expected_revision" => 1, "items" => []},
               gov
             )

    assert {:ok, ^order} = Orders.place(latest, %{"margherita" => 2}, "Ada", "fresh")
    assert Orders.menu(Restaurant.published_menu(r)) == []

    revoke = %{"merchant_id" => r.merchant, "key_id" => r.boards["board-1"].signer.key_id}
    assert {:ok, _} = Management.approve(@url, r.chapter, "revoke-device", revoke, gov)
    refute Restaurant.active_board?(r, "board-1")
    assert Orders.step(r, "board-1", order, :accept, 0) == {:error, :forbidden}
    assert %{state: :placed} = Orders.get(r, order)
  end

  defp post(path, body, headers \\ []) do
    {:ok, _} = Application.ensure_all_started(:inets)

    {:ok, {{_, status, _}, _, raw}} =
      :httpc.request(
        :post,
        {String.to_charlist(@url <> path), headers, ~c"application/json", Jason.encode!(body)},
        [],
        body_format: :binary
      )

    {status, raw}
  end
end
