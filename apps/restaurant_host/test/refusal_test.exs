defmodule RestaurantHost.RefusalTest do
  @moduledoc """
  What a restaurant operator is told when a governance command is refused:
  the host names a ledger refusal from one closed table, by its head atom
  alone, and the operator's clients decode it without making an atom.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CoopSubstrate.{Crypto, KeyFence, Log}
  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.Protocol.Envelope
  alias RestaurantHost.{DeviceGrants, Enrollment, Management, Refusal, World}

  @port 4074
  @url "http://127.0.0.1:#{@port}"
  @tenant "11111111-1111-1111-1111-111111111111"

  @ledger ~w(key_not_separate restaurant_key_already_granted restaurant_device_not_active
             stale_menu invalid_restaurant_menu invalid_restaurant_grant invalid_dispatch_tenant
             invalid_dispatch_grant restaurant_governance_not_declared role_key_not_declared
             invalid_signature)a
  @host ~w(forbidden unknown_device bad_request unknown_command signature_count
           unknown_governance_key not_admitted)a
  @client ~w(not_what_was_shown unexpected_proposal governance_key_unavailable invalid_options
             not_granted)a

  test "the host names a ledger refusal by its head atom, and only from the table" do
    assert Enum.sort(Refusal.ledger_codes()) == Enum.sort(@ledger)
    assert Refusal.code(:unknown_command) == "unknown_command"
    assert Refusal.code({:invalid, :key_not_separate}) == "key_not_separate"
    assert Refusal.code({:reject, 0, :stale_menu}) == "stale_menu"
    assert Refusal.code({:invalid_signature, "k1"}) == "invalid_signature"

    for wrapped <- [
          {:reject, 0, {:role_key_not_declared, "governance", "k1"}},
          {:invalid, {:role_key_not_declared, "governance", "k1"}}
        ] do
      named = Refusal.code(wrapped)
      assert named == "role_key_not_declared"
      refute named =~ "k1"
    end

    for opaque <- [
          {:invalid, :dispatcher_key_already_granted},
          {:invalid, {:undeclarable_role, "k1"}},
          {:reject, 0, {:role_key_already_declared, "steward", "k1"}},
          {:reject, :index, :key_not_separate},
          {:store_append_failed, :timeout},
          "key_not_separate",
          %{error: :key_not_separate},
          {}
        ],
        do: assert(Refusal.code(opaque) == "not_admitted")
  end

  test "the clients decode every known code, and anything else to the fallback" do
    for code <- @ledger ++ @host ++ @client do
      body = Jason.encode!(%{error: code})
      assert Refusal.decode({:error, {422, body}}, :fallback) == code
      assert Refusal.decode({:error, code}, :fallback) == code
      assert Refusal.explain(code) =~ ~r/\A#{code}: \S/
    end

    for code <- @ledger do
      body = Jason.encode!(%{error: Refusal.code({:invalid, code})})
      assert Refusal.decode({:error, {422, body}}, nil) == code
    end

    assert Refusal.decode({:error, :not_what_was_shown}, :not_granted) == :not_what_was_shown

    # The host's own refusals keep their statuses.
    for {status, code} <- [{403, :forbidden}, {404, :unknown_device}],
        do: assert(Refusal.decode({:error, {status, Jason.encode!(%{error: code})}}, nil) == code)

    for undecodable <- [
          {:error, {422, "not json"}},
          {:error, {422, ~s({"other":"stale_menu"})}},
          {:error, {500, ~s({"error":{"code":"stale_menu"}})}},
          {:error, :econnrefused},
          {:error, {:failed_connect, []}},
          {:ok, %{}},
          :error
        ],
        do: assert(Refusal.decode(undecodable, :fallback) == :fallback)
  end

  test "decoding an unknown or hostile code makes no atom" do
    bodies =
      for code <- ["<script>alert(1)</script>", "unknown_#{System.unique_integer([:positive])}"],
          do: Jason.encode!(%{error: code})

    assert Refusal.decode({:error, {422, ~s({"error":"stale_menu"})}}, nil) == :stale_menu
    before = :erlang.system_info(:atom_count)
    for body <- bodies, do: assert(Refusal.decode({:error, {422, body}}, :fallback) == :fallback)
    assert :erlang.system_info(:atom_count) == before
  end

  test "describe shows a decoded code's sentence, else the error as before" do
    named = {:error, {422, ~s({"error":"stale_menu"})}}
    assert Refusal.describe(named) == Refusal.explain(:stale_menu)
    assert Refusal.describe({:error, :not_what_was_shown}) =~ "not_what_was_shown: "
    assert Refusal.explain(:invalid_server) == "invalid_server"

    for error <- [{:error, :enoent}, {:error, {500, "<html>"}}],
        do: assert(Refusal.describe(error) == inspect(error, limit: 5))

    long = {:error, Enum.to_list(1..20)}
    assert Refusal.describe(long) == inspect(long, limit: 5)
    refute Refusal.describe(long) == inspect(long)
  end

  test "every refusal the chapter key fence makes is named" do
    for rule <- KeyFence.rules(), do: assert(KeyFence.refusal(rule) in Refusal.ledger_codes())
  end

  describe "over HTTP" do
    setup do
      dir = Path.join(System.tmp_dir!(), "rh-refusal-keys-#{System.unique_integer([:positive])}")
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
        {Bandit, plug: RestaurantHost.Web.Endpoint, ip: {127, 0, 0, 1}, port: @port},
        id: :host
      )

      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
      {:ok, World.build(grant: false, governance: gov) |> Map.put(:gov, gov)}
    end

    test "a Dispatch key on the storefront's device key is named at prepare", %{
      restaurant: r,
      gov: gov
    } do
      :ok = enroll(r, "storefront")
      head = Log.head()
      dispatch = dispatch(r, r.storefront.signer.pubkey)
      error = Management.approve(@url, r.chapter, "grant-dispatch", dispatch, gov)

      assert refused(error) == "key_not_separate"
      assert Refusal.describe(error) =~ "key_not_separate: "
      assert Log.head() == head
    end

    test "a collision made between prepare and submit is named from the append", %{
      restaurant: r,
      gov: gov
    } do
      {pubkey, _seed} = Crypto.generate_keypair()
      {:ok, held} = Management.prepare(r, "grant-dispatch", dispatch(r, pubkey), gov.key_id)
      declare!(r, gov, "steward", "k-steward", pubkey)
      head = Log.head()

      assert submit("/api/restaurant-management/grant-dispatch/", held, gov.seed) ==
               {422, ~s({"error":"key_not_separate"})}

      assert Log.head() == head
    end

    test "a repeat grant, a stale menu and an unknown key are named", %{restaurant: r, gov: gov} do
      :ok = enroll(r, "board-1")
      assert enroll(r, "board-1") == {:error, :restaurant_key_already_granted}

      menu = %{
        "merchant_id" => r.merchant,
        "currency" => "USD",
        "expected_revision" => 0,
        "items" => []
      }

      assert {:ok, _} = Management.approve(@url, r.chapter, "publish-menu", menu, gov)

      assert refused(Management.approve(@url, r.chapter, "publish-menu", menu, gov)) ==
               "stale_menu"

      revoke = %{"merchant_id" => r.merchant, "key_id" => "k-unknown"}

      assert refused(Management.approve(@url, r.chapter, "revoke-device", revoke, gov)) ==
               "restaurant_device_not_active"
    end

    test "a governance key revoked before submit is named; its key ID is only logged", %{
      restaurant: r,
      gov: gov
    } do
      {:ok, held} = DeviceGrants.prepare(r, "board-1", gov.key_id)
      {successor, _seed} = Crypto.generate_keypair()
      declare!(r, gov, "governance", "k-successor", successor)
      append!(r, gov, "RoleKeyRevoked", %{"role" => "governance", "key_id" => gov.key_id})
      level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: level) end)

      log =
        capture_log([level: :info], fn ->
          assert {422, body} = submit("/api/device-grants/board-1/", held, gov.seed)
          assert Jason.decode!(body) == %{"error" => "role_key_not_declared"}
          refute body =~ gov.key_id
        end)

      assert log =~ inspect({:reject, 0, {:role_key_not_declared, "governance", gov.key_id}})
    end

    test "a signature by another key is named", %{restaurant: r, gov: gov} do
      {:ok, held} = DeviceGrants.prepare(r, "board-1", gov.key_id)
      {_pubkey, rogue} = Crypto.generate_keypair()

      assert submit("/api/device-grants/board-1/", held, rogue) ==
               {422, ~s({"error":"invalid_signature"})}
    end

    test "the anonymous device route names only an unknown device, as before" do
      assert get("/api/device-grants/board-9") == {404, ~s({"error":"unknown_device"})}
    end

    test "a host that stops answering is not_granted after the proposal, else unexpected", %{
      restaurant: r
    } do
      head = Log.head()
      stop = fn _prompt -> stop_supervised!(:host) == :ok end
      io = %{info: fn _ -> :ok end, confirm: stop}

      assert Enrollment.run(List.delete(args(r, "board-1"), "--yes"), io) ==
               {:error, :not_granted}

      assert enroll(r, "board-1") == {:error, :unexpected_proposal}
      assert Log.head() == head
    end

    test "enrolling a board on a declared role key names the refusal", %{restaurant: r, gov: gov} do
      declare!(r, gov, "steward", "k-steward", r.boards["board-1"].signer.pubkey)
      assert enroll(r, "board-1") == {:error, :key_not_separate}

      assert_raise Mix.Error, ~r/cannot grant: key_not_separate: /, fn ->
        Mix.Tasks.Restaurant.Grant.run(args(r, "board-1"))
      end
    end
  end

  defp args(r, device),
    do: [device, "--chapter", r.chapter, "--merchant", r.merchant, "--server", @url, "--yes"]

  defp enroll(r, device),
    do: Enrollment.run(args(r, device), %{info: fn _ -> :ok end, confirm: fn _ -> true end})

  defp dispatch(r, pubkey) do
    %{
      "merchant_id" => r.merchant,
      "key_id" => "k-dispatch",
      "tenant_id" => @tenant,
      "pubkey" => Base.url_encode64(pubkey, padding: false)
    }
  end

  defp refused({:error, {422, body}}), do: Jason.decode!(body)["error"]

  defp declare!(r, gov, role, key_id, pubkey),
    do:
      append!(r, gov, "RoleKeyDeclared", %{
        "role" => role,
        "key_id" => key_id,
        "pubkey" => {:bytes, pubkey}
      })

  defp append!(r, gov, type, payload) do
    {:ok, env} =
      Envelope.new(%{
        chapter_id: r.chapter,
        type: type,
        payload: payload,
        signers: [Map.take(gov, [:role, :key_id, :pubkey])],
        timestamp_ms: System.system_time(:millisecond)
      })

    {:ok, signed} = Envelope.sign(env, gov.key_id, gov.seed)
    {:ok, _} = Log.append(signed)
  end

  defp submit(path, held, seed) do
    signature = Base.url_encode64(Crypto.sign(held.signing_bytes, seed), padding: false)
    post(path <> held.id, %{"signature" => signature})
  end

  defp get(path), do: request(:get, {String.to_charlist(@url <> path), []})

  defp post(path, body),
    do:
      request(
        :post,
        {String.to_charlist(@url <> path), [], ~c"application/json", Jason.encode!(body)}
      )

  defp request(method, request) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, {{_, status, _}, _, raw}} = :httpc.request(method, request, [], body_format: :binary)
    {status, raw}
  end
end
