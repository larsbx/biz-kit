defmodule RestaurantHost.MenuItemsTest do
  @moduledoc """
  `mix restaurant.menu` against the host over real HTTP (decommission D6): the
  administrator's governance key signs exactly the menu item shown, at the
  menu version it was shown against, and the storefront serves it at once.
  """
  use ExUnit.Case, async: false

  alias CoopSubstrate.{Canonical, Log}
  alias CoopSubstrate.Harness.Ops
  alias RestaurantHost.{MenuItems, Orders, World}

  @port 4074
  @url "http://127.0.0.1:#{@port}"

  setup do
    dir = Path.join(System.tmp_dir!(), "rh-menu-keys-#{System.unique_integer([:positive])}")
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
    {:ok, Map.merge(w, %{gov: gov, dir: dir})}
  end

  defp write_item(ctx, item) do
    path = Path.join(ctx.dir, "item-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(item))
    path
  end

  defp menu!(ctx, path, extra \\ []),
    do:
      Mix.Tasks.Restaurant.Menu.run(
        ["put", path, "--chapter", ctx.chapter, "--merchant", "shop", "--server", @url, "--yes"] ++
          extra
      )

  test "a new item, with a discount, is reviewed, signed and on the storefront", ctx do
    lunch = %{"id" => "lunch", "method" => "percent_off", "rate" => "0.1"}
    path = write_item(ctx, World.item("calzone", "Calzone", "CALZ", 1500, [lunch]))

    menu!(ctx, path)
    assert_received {:mix_shell, :info, [shown]}
    assert shown =~ "menu version 2"
    assert shown =~ "new item calzone"
    assert shown =~ "Calzone (CALZ) 1500 USD, published"
    assert shown =~ "lunch: percent_off rate 0.1"
    assert_received {:mix_shell, :info, ["menu updated: event " <> _]}

    assert {:ok, %{lines: [%{discount_rule: "lunch"}]}} =
             Orders.price(ctx.restaurant, %{"calzone" => 1})
  end

  test "repricing shows the old item; a stale review cannot be signed", ctx do
    path = write_item(ctx, World.item("margherita", "Margherita", "MARG", 1300))
    menu!(ctx, path)
    assert_received {:mix_shell, :info, [shown]}
    assert shown =~ "replaces Margherita (MARG) 1250 USD, published"
    assert shown =~ "with     Margherita (MARG) 1300 USD, published"

    # An edit someone else made between review and signature: the held version
    # no longer matches the menu, and the Log refuses it.
    {:ok, held} =
      MenuItems.prepare(
        ctx.restaurant,
        "margherita",
        World.item("margherita", "Margherita", "MARG", 1400),
        3,
        ctx.gov.key_id
      )

    World.put_item!(
      ctx.chapter,
      ctx.governance,
      World.item("margherita", "Margherita", "MARG", 1350),
      3
    )

    sig = CoopSubstrate.Crypto.sign(held.signing_bytes, ctx.gov.seed)
    head = Log.head()
    assert {:error, _} = MenuItems.submit(ctx.restaurant, "margherita", held.id, sig)
    assert Log.head() == head
  end

  test "the tool signs only exactly the item and version shown", ctx do
    item = World.item("calzone", "Calzone", "CALZ", 1500)
    {:ok, held} = MenuItems.prepare(ctx.restaurant, "calzone", item, 2, ctx.gov.key_id)
    {:ok, core} = Canonical.decode(held.signing_bytes)
    assert MenuItems.matches?(core, ctx.chapter, "shop", item, 2)

    for tampered <- [
          put_in(core, ["payload", "price_minor"], 1),
          put_in(core, ["payload", "expected_version"], 3),
          put_in(core, ["payload", "merchant_id"], "other"),
          put_in(core, ["payload", "discounts"], [
            %{"id" => "x", "method" => "unit_price", "price_minor" => 0}
          ]),
          Map.put(core, "chapter_id", "other-chapter"),
          Map.put(core, "type", "RestaurantDeviceGrantedV1")
        ],
        do: refute(MenuItems.matches?(tampered, ctx.chapter, "shop", item, 2))
  end

  test "an invalid item, another chapter or an unauthenticated request appends nothing", ctx do
    head = Log.head()

    bad = write_item(ctx, World.item("calzone", "Calzone", "MARG", 1500))
    assert_raise Mix.Error, ~r/cannot update the menu/, fn -> menu!(ctx, bad) end

    ok = write_item(ctx, World.item("calzone", "Calzone", "CALZ", 1500))

    assert_raise Mix.Error, ~r/cannot update the menu/, fn ->
      Mix.Tasks.Restaurant.Menu.run([
        "put",
        ok,
        "--chapter",
        "other",
        "--merchant",
        "shop",
        "--server",
        @url,
        "--yes"
      ])
    end

    body = %{
      "chapter_id" => ctx.chapter,
      "merchant_id" => "shop",
      "governance_key_id" => ctx.gov.key_id,
      "expected_version" => 2,
      "item" => World.item("calzone", "Calzone", "CALZ", 1500)
    }

    assert {403, _} = post("/api/menu-items/calzone", body)
    assert Log.head() == head
  end

  test "declining review signs nothing", ctx do
    path = write_item(ctx, World.item("calzone", "Calzone", "CALZ", 1500))
    send(self(), {:mix_shell_input, :yes?, false})

    Mix.Tasks.Restaurant.Menu.run([
      "put",
      path,
      "--chapter",
      ctx.chapter,
      "--merchant",
      "shop",
      "--server",
      @url
    ])

    assert_received {:mix_shell, :info, ["not updated; nothing was signed"]}
    assert Enum.map(Orders.menu(ctx.restaurant), & &1.id) == ~w(margherita pepperoni)
  end

  test "the menu is public, in wire form, with its version", ctx do
    {:ok, _} = Application.ensure_all_started(:inets)

    {:ok, {{_, 200, _}, _, raw}} =
      :httpc.request(:get, {String.to_charlist(@url <> "/api/menu"), []}, [],
        body_format: :binary
      )

    assert %{"version" => 2, "items" => items} = Jason.decode!(raw)
    assert Enum.map(items, & &1["item_id"]) == ~w(margherita pepperoni)
    assert hd(items) == World.item("margherita", "Margherita", "MARG", 1250)
    _ = ctx
  end

  defp post(path, body) do
    {:ok, _} = Application.ensure_all_started(:inets)

    {:ok, {{_, status, _}, _, raw}} =
      :httpc.request(
        :post,
        {String.to_charlist(@url <> path), [], ~c"application/json", Jason.encode!(body)},
        [],
        body_format: :binary
      )

    {status, raw}
  end
end
