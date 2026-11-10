defmodule RestaurantHost.DeviceRevocationTest do
  @moduledoc """
  `mix restaurant.revoke` against the host over real HTTP: the administrator
  sees which device a key is, signs exactly its revocation, and from then on
  nothing that key signs reaches the ledger.
  """
  use ExUnit.Case, async: false

  alias CoopSubstrate.{Canonical, Log}
  alias CoopSubstrate.Harness.Ops
  alias RestaurantHost.{DeviceRevocations, Orders, World}

  @port 4075
  @url "http://127.0.0.1:#{@port}"

  setup do
    dir = Path.join(System.tmp_dir!(), "rh-revoke-keys-#{System.unique_integer([:positive])}")
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

    w = World.build(governance: gov)
    {:ok, Map.put(w, :gov, gov)}
  end

  defp board_key(r), do: r.boards["board-1"].signer.key_id

  defp revoke!(ctx, key, extra \\ ["--yes"]),
    do:
      Mix.Tasks.Restaurant.Revoke.run(
        [key, "--chapter", ctx.chapter, "--merchant", "shop", "--server", @url] ++ extra
      )

  test "a revoked board's steps are refused; orders and other devices carry on", ctx do
    r = ctx.restaurant
    {:ok, id} = Orders.place(r, %{"margherita" => 1}, "Ada", "k-1")

    revoke!(ctx, board_key(r))
    assert_received {:mix_shell, :info, [shown]}
    assert shown =~ "device    board-1 (key #{board_key(r)})"
    assert shown =~ "acts as   staff: accept, start_preparing, mark_ready, complete, cancel"
    assert_received {:mix_shell, :info, ["revoked: event " <> _]}

    assert Orders.step(r, "board-1", id, :accept, 0) == {:error, :forbidden}
    assert {:ok, _} = Orders.place(r, %{"margherita" => 1}, "Grace", "k-2")
    assert %{state: :placed} = Orders.get(r, id)

    # Revoked for good: a second revocation, and a re-grant of the key, are refused.
    assert_raise Mix.Error, ~r/cannot revoke/, fn -> revoke!(ctx, board_key(r)) end

    assert_raise Mix.Error, ~r/cannot grant/, fn ->
      Mix.Tasks.Restaurant.Grant.run([
        "board-1",
        "--chapter",
        ctx.chapter,
        "--merchant",
        "shop",
        "--server",
        @url,
        "--yes"
      ])
    end
  end

  test "the tool signs only exactly the revocation shown", ctx do
    key = board_key(ctx.restaurant)
    {:ok, held} = DeviceRevocations.prepare(ctx.restaurant, key, ctx.gov.key_id)
    {:ok, core} = Canonical.decode(held.signing_bytes)
    assert DeviceRevocations.matches?(core, ctx.chapter, "shop", key)

    for tampered <- [
          put_in(core, ["payload", "key_id"], ctx.restaurant.storefront.signer.key_id),
          put_in(core, ["payload", "merchant_id"], "other"),
          Map.put(core, "chapter_id", "other"),
          Map.put(core, "type", "RestaurantDeviceGrantedV1")
        ],
        do: refute(DeviceRevocations.matches?(tampered, ctx.chapter, "shop", key))
  end

  test "an unknown key, or an unsigned request, revokes nothing", ctx do
    head = Log.head()
    assert_raise Mix.Error, ~r/cannot revoke: unknown_device/, fn -> revoke!(ctx, "k-nobody") end

    {:ok, _} = Application.ensure_all_started(:inets)

    {:ok, {{_, 403, _}, _, _}} =
      :httpc.request(:get, {String.to_charlist(@url <> "/api/devices"), []}, [], [])

    body =
      Jason.encode!(%{
        "chapter_id" => ctx.chapter,
        "merchant_id" => "shop",
        "governance_key_id" => ctx.gov.key_id
      })

    {:ok, {{_, 403, _}, _, _}} =
      :httpc.request(
        :post,
        {String.to_charlist(@url <> "/api/device-revocations/" <> board_key(ctx.restaurant)), [],
         ~c"application/json", body},
        [],
        []
      )

    assert Log.head() == head
  end

  test "declining review signs nothing", ctx do
    send(self(), {:mix_shell_input, :yes?, false})
    revoke!(ctx, board_key(ctx.restaurant), [])
    assert_received {:mix_shell, :info, ["not revoked; nothing was signed"]}
    {:ok, id} = Orders.place(ctx.restaurant, %{"margherita" => 1}, "Ada", "k-1")
    assert Orders.step(ctx.restaurant, "board-1", id, :accept, 0) == :ok
  end
end
