defmodule RestaurantHost.World do
  @moduledoc """
  A restaurant in a fresh Log chapter, so tests share the ledger without a
  reset: a declared governance key grants a storefront device (`checkout`) and
  one kitchen board (staff), as `RestaurantHost.DeviceGrants` would, and the
  host is configured to sign as them.

  Dispatch is played by the test: its transport key is generated here, granted
  by the test-held governance key and returned as `ctx.transport`; it never
  enters the host's configuration or application env.
  """

  alias CoopSubstrate.{Crypto, Log, ULID}
  alias CoopSubstrate.Protocol.Envelope
  alias RestaurantHost.{DeviceGrants, Orders, Restaurant}

  @doc """
  Options: `grant: false` leaves the devices ungranted; `governance:` a signer
  (`%{key_id, pubkey, seed}`, e.g. from `CoopSubstrate.Harness.Ops`) to declare
  instead of a fresh key; `delivery: %{fee_minor: n}` adds a delivery section;
  `transport: true` grants the merchant a Dispatch transport key.
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
      },
      delivery: opts[:delivery]
    })

    r = Restaurant.current()

    if Keyword.get(opts, :grant, true) do
      for device <- ["storefront", "board-1"] do
        {:ok, d} = DeviceGrants.details(r, device)
        append!(chapter, gov, d.type, d.payload)
      end
    end

    ctx = %{restaurant: r, secret: secret, chapter: chapter, governance: gov}

    if opts[:transport],
      do: Map.put(ctx, :transport, grant_transport(ctx)),
      else: ctx
  end

  @doc "A fresh Dispatch transport key, granted by governance for `merchant` as `dispatch_id`."
  def grant_transport(ctx, merchant \\ "shop", dispatch_id \\ "dispatch-test") do
    key = key("dispatch_transport")

    append!(ctx.chapter, ctx.governance, "RestaurantTransportGrantedV1", %{
      "merchant_id" => merchant,
      "dispatch_id" => dispatch_id,
      "key_id" => key.signer.key_id,
      "pubkey" => {:bytes, key.signer.pubkey}
    })

    Map.put(key, :dispatch_id, dispatch_id)
  end

  @doc """
  Sign one Dispatch step for the order's current request at its current
  handoff version, with the op's fields (overridable), and submit it.
  """
  def transport(ctx, order_id, op, fields \\ %{}, key \\ nil) do
    key = key || ctx.transport
    %{handoff: handoff} = Orders.get(ctx.restaurant, order_id)
    step = "step-" <> ULID.generate()

    defaults =
      case op do
        "accept" -> %{"transport_ref" => "trip-" <> order_id}
        "reject" -> %{"reason" => "no drivers"}
        "delivered" -> %{"proof" => {:bytes, :crypto.hash(:sha256, step)}}
        "failed" -> %{"reason" => "nobody home", "proof" => {:bytes, :crypto.hash(:sha256, step)}}
        _ -> %{}
      end

    payload =
      %{
        "merchant_id" => ctx.restaurant.merchant,
        "order_id" => order_id,
        "request_id" => handoff.request_id,
        "step_id" => step,
        "expected_version" => handoff.version,
        "op" => op
      }
      |> Map.merge(defaults)
      |> Map.merge(fields)
      |> Map.reject(fn {_, v} -> v == nil end)

    case append(ctx.chapter, key, "RestaurantTransportStepV1", payload) do
      {:ok, _} -> :ok
      {:error, {:reject, 0, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  def transport!(ctx, order_id, op, fields \\ %{}), do: :ok = transport(ctx, order_id, op, fields)

  defp key(role) do
    {pubkey, seed} = Crypto.generate_keypair()
    key_id = "k-" <> Base.encode16(binary_part(pubkey, 0, 6), case: :lower)
    %{seed: seed, signer: %{role: role, pubkey: pubkey, key_id: key_id}}
  end

  defp append!(chapter, member, type, payload),
    do: {:ok, _} = append(chapter, member, type, payload)

  defp append(chapter, member, type, payload) do
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
    Log.append(signed)
  end
end
