defmodule RestaurantHost.World do
  @moduledoc """
  A restaurant in a fresh Log chapter, so tests share the ledger without a
  reset: a declared governance key grants a storefront device (`checkout`) and
  one kitchen board (staff), as `RestaurantHost.DeviceGrants` would, and the
  host is configured to sign as them.
  """

  alias CoopSubstrate.{Crypto, Log, ULID}
  alias CoopSubstrate.Protocol.Envelope
  alias RestaurantHost.{DeviceGrants, Restaurant}

  @doc """
  Options: `grant: false` leaves the devices ungranted; `menu:` and
  `timezone:` replace the default menu (wire items, see `item/5`, put on the
  Log with the governance key) and UTC; `governance:` a signer
  (`%{key_id, pubkey, seed}`, e.g. from `CoopSubstrate.Harness.Ops`) to declare
  instead of a fresh key.
  """
  def build(opts \\ []) do
    chapter = "rh-" <> ULID.generate()

    gov =
      case opts[:governance] do
        nil -> key("governance")
        g -> %{seed: g.seed, signer: %{role: "governance", key_id: g.key_id, pubkey: g.pubkey}}
      end

    storefront = key("restaurant_device")
    board = key("restaurant_device")
    secret = "pair-" <> ULID.generate()

    append!(chapter, gov, "RoleKeyDeclared", %{
      "role" => "governance",
      "key_id" => gov.signer.key_id,
      "pubkey" => {:bytes, gov.signer.pubkey}
    })

    Application.put_env(:restaurant_host, :restaurant, %{
      chapter: chapter,
      merchant: "shop",
      currency: :USD,
      jurisdiction: "US-MI",
      timezone: Keyword.get(opts, :timezone, "Etc/UTC"),
      storefront: %{
        device_id: "storefront",
        key_id: storefront.signer.key_id,
        seed: storefront.seed
      },
      boards: %{
        "board-1" => %{
          device_id: "board-1",
          key_id: board.signer.key_id,
          seed: board.seed,
          pairing_sha256: :crypto.hash(:sha256, secret)
        }
      }
    })

    r = Restaurant.current()

    opts
    |> Keyword.get(:menu, [
      item("margherita", "Margherita", "MARG", 1250),
      item("pepperoni", "Pepperoni", "PEPP", 1400)
    ])
    |> Enum.with_index()
    |> Enum.each(fn {i, version} -> put_item!(chapter, gov, i, version) end)

    if Keyword.get(opts, :grant, true) do
      for device <- ["storefront", "board-1"] do
        {:ok, d} = DeviceGrants.details(r, device)
        append!(chapter, gov, d.type, d.payload)
      end
    end

    %{restaurant: r, secret: secret, chapter: chapter, governance: gov}
  end

  @doc "Put a menu item on the Log, signed by the world's governance key."
  def put_item!(chapter, gov, item, version),
    do:
      append!(
        chapter,
        gov,
        "RestaurantMenuItemPutV1",
        Map.merge(item, %{"merchant_id" => "shop", "expected_version" => version})
      )

  @doc "A published USD menu item in its signed wire form."
  def item(id, name, sku, price_minor, discounts \\ []),
    do: %{
      "item_id" => id,
      "name" => name,
      "sku" => sku,
      "price_minor" => price_minor,
      "currency" => "USD",
      "visibility" => "published",
      "discounts" => discounts
    }

  defp key(role) do
    {pubkey, seed} = Crypto.generate_keypair()
    key_id = "k-" <> Base.encode16(binary_part(pubkey, 0, 6), case: :lower)
    %{seed: seed, signer: %{role: role, pubkey: pubkey, key_id: key_id}}
  end

  defp append!(chapter, member, type, payload) do
    {:ok, env} =
      Envelope.new(%{
        event_id: ULID.generate(),
        chapter_id: chapter,
        type: type,
        payload: payload,
        signers: [member.signer],
        auth_ref: nil,
        timestamp_ms: System.system_time(:millisecond)
      })

    {:ok, signed} = Envelope.sign(env, member.signer.key_id, member.seed)
    {:ok, _} = Log.append(signed)
  end
end
