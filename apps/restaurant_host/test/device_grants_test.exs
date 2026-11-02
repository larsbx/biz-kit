defmodule RestaurantHost.DeviceGrantsTest do
  @moduledoc """
  `mix restaurant.grant` against the host over real HTTP: the administrator's
  governance key, held on their machine, signs exactly the grant shown, and
  only then do the device's orders and steps reach the ledger.
  """
  use ExUnit.Case, async: false

  alias CoopSubstrate.{Canonical, Crypto, Log}
  alias CoopSubstrate.Harness.Ops
  alias RestaurantHost.{DeviceGrants, Orders, World}

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

  defp grant!(device), do: Mix.Tasks.Restaurant.Grant.run([device, "--server", @url, "--yes"])

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

    assert_raise Mix.Error, ~r/cannot grant: \{404/, fn -> grant!("board-9") end
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
             DeviceGrants.submit("board-1", held.id, Crypto.sign(held.signing_bytes, rogue))

    assert Log.head() == head
    assert DeviceGrants.prepare(r, "board-1", "k-not-governance") |> elem(0) == :error
  end
end
