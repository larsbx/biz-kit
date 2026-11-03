defmodule RestaurantHost.Restaurant do
  @moduledoc """
  One restaurant as this host serves it: its Log chapter and merchant, its menu
  (a `CommerceCore.Catalog`), its tax rate, and the devices it signs for.

  A device is a key a governance grant (`RestaurantDeviceGrantedV1`) has bound
  to this merchant: the storefront (granted `checkout`) and each paired kitchen
  board. The host holds their seeds; a board acts only once paired with its
  secret. Built from the `:restaurant_host, :restaurant` application env.
  """

  alias CommerceCore.Catalog
  alias CoopSubstrate.Crypto

  @enforce_keys [:chapter, :merchant, :currency, :tax_rate, :catalog, :menu, :storefront, :boards]
  defstruct @enforce_keys

  def current, do: :restaurant_host |> Application.fetch_env!(:restaurant) |> build()

  @doc """
  Build and install a replacement configuration before exposing it to readers.
  Production calls this at startup; explicit reconfiguration replaces the whole
  derived model. A failed build leaves the previous configuration intact.
  """
  def configure(config) do
    restaurant = build(config)
    Application.put_env(:restaurant_host, :restaurant, restaurant)
    restaurant
  end

  @doc "A restaurant from its configuration (raises on an invalid one)."
  def build(%__MODULE__{} = restaurant), do: restaurant

  def build(config) do
    currency = Map.fetch!(config, :currency)
    merchant = Map.fetch!(config, :merchant)
    menu = Map.fetch!(config, :menu)

    {:ok, empty} = Catalog.new(merchant)

    catalog =
      menu
      |> Enum.with_index()
      |> Enum.reduce(empty, fn {item, version}, catalog ->
        {:ok, catalog} =
          Catalog.put(catalog, merchant, version, %{
            id: item.id,
            sku: item.sku,
            visibility: :published,
            prices: %{currency => Money.from_integer(item.price_minor, currency)}
          })

        catalog
      end)

    %__MODULE__{
      chapter: Map.fetch!(config, :chapter),
      merchant: merchant,
      currency: currency,
      tax_rate: Decimal.new(Map.get(config, :tax_rate, "0")),
      catalog: catalog,
      menu: Enum.map(menu, &Map.take(&1, [:id, :name])),
      storefront: device(Map.fetch!(config, :storefront)),
      boards: Map.new(Map.get(config, :boards, %{}), fn {id, d} -> {id, device(d)} end)
    }
  end

  defp device(%{device_id: id, key_id: key_id, seed: <<_::256>> = seed} = config) do
    %{
      device_id: id,
      seed: seed,
      pairing_sha256: Map.get(config, :pairing_sha256),
      signer: %{role: "restaurant_device", key_id: key_id, pubkey: Crypto.pubkey_from_seed(seed)}
    }
  end

  @doc "The board a pairing secret opens, compared in constant time."
  def pair(%__MODULE__{boards: boards}, board_id, secret) when is_binary(secret) do
    with %{pairing_sha256: <<_::256>> = expected} <- Map.get(boards, board_id),
         true <- Plug.Crypto.secure_compare(:crypto.hash(:sha256, secret), expected) do
      {:ok, board_id}
    else
      _ -> :error
    end
  end

  def pair(_, _, _), do: :error
end
