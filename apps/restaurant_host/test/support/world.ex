defmodule RestaurantHost.World do
  @moduledoc """
  A restaurant in a fresh Log chapter, so tests share the ledger without a
  reset: a declared governance key grants a storefront device (`checkout`) and
  one kitchen board (staff), and the host is configured to sign as them.
  """

  alias CoopSubstrate.{Crypto, Log, ULID}
  alias CoopSubstrate.Protocol.Envelope
  alias RestaurantHost.Restaurant

  @board_actions ~w(accept start_preparing mark_ready complete cancel)

  def build do
    chapter = "rh-" <> ULID.generate()
    gov = key("governance")
    storefront = key("restaurant_device")
    board = key("restaurant_device")
    secret = "pair-" <> ULID.generate()

    append!(chapter, gov, "RoleKeyDeclared", %{
      "role" => "governance",
      "key_id" => gov.signer.key_id,
      "pubkey" => {:bytes, gov.signer.pubkey}
    })

    for {device, id, actor, actions} <- [
          {storefront, "storefront", "system", ["checkout"]},
          {board, "board-1", "staff", @board_actions}
        ] do
      append!(chapter, gov, "RestaurantDeviceGrantedV1", %{
        "merchant_id" => "shop",
        "device_id" => id,
        "key_id" => device.signer.key_id,
        "pubkey" => {:bytes, device.signer.pubkey},
        "actor" => actor,
        "actions" => actions
      })
    end

    Application.put_env(:restaurant_host, :restaurant, %{
      chapter: chapter,
      merchant: "shop",
      currency: :USD,
      tax_rate: "0.0825",
      menu: [
        %{id: "margherita", name: "Margherita", sku: "MARG", price_minor: 1250},
        %{id: "pepperoni", name: "Pepperoni", sku: "PEPP", price_minor: 1400}
      ],
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

    %{restaurant: Restaurant.current(), secret: secret, chapter: chapter}
  end

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
