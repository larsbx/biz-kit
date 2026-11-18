defmodule RestaurantHost.Restaurant do
  @moduledoc """
  One restaurant as this host serves it: its Log chapter and merchant, its menu
  (a `CommerceCore.Catalog`), its tax jurisdiction, and the devices it signs for.

  A device is a key a governance grant (`RestaurantDeviceGrantedV1`) has bound
  to this merchant: the storefront (granted `checkout`) and each paired kitchen
  board. The host holds their seeds; a board acts only once paired with its
  secret. Built from the `:restaurant_host, :restaurant` application env.
  """

  alias CommerceCore.Catalog
  alias CoopSubstrate.{Crypto, Log}
  alias RestaurantCore.Admission

  @enforce_keys [
    :chapter,
    :merchant,
    :currency,
    :jurisdiction,
    :tax,
    :catalog,
    :menu,
    :storefront,
    :boards
  ]
  defstruct @enforce_keys ++ [menu_revision: 0, delivery_enabled: false, delivery_site: nil]

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

    jurisdiction = Map.fetch!(config, :jurisdiction)

    tax =
      case CommerceCore.Tax.Jurisdictions.profile(jurisdiction) do
        {:ok, tax} -> tax
        {:error, reason} -> raise ArgumentError, "#{reason}: #{inspect(jurisdiction)}"
      end

    %__MODULE__{
      chapter: Map.fetch!(config, :chapter),
      merchant: merchant,
      currency: currency,
      jurisdiction: jurisdiction,
      tax: tax,
      catalog: nil,
      menu: [],
      delivery_enabled: Map.get(config, :delivery_enabled, false),
      delivery_site: Map.get(config, :delivery_site),
      storefront: device(Map.fetch!(config, :storefront)),
      boards: Map.new(Map.get(config, :boards, %{}), fn {id, d} -> {id, device(d)} end)
    }
    |> put_menu(menu, 0)
  end

  @doc "Read the signed menu; the configured bootstrap menu is revision zero."
  def published_menu(%__MODULE__{} = r) do
    currency = Atom.to_string(r.currency)

    case Admission.menu(Log.gate().restaurant, r.chapter, r.merchant) do
      nil ->
        r

      %{revision: revision, currency: ^currency, items: items} ->
        menu =
          for item <- items do
            %{
              id: item["id"],
              sku: item["sku"],
              name: item["name"],
              price_minor: item["price_minor"],
              discount_minor: Map.get(item, "discount_minor", 0)
            }
          end

        put_menu(r, menu, revision)

      %{revision: revision} ->
        put_menu(r, [], revision)
    end
  end

  def delivery_available?(%__MODULE__{delivery_enabled: true} = r),
    do: Admission.dispatch_available?(Log.gate().restaurant, r.chapter, r.merchant)

  def delivery_available?(_), do: false

  def active_board?(%__MODULE__{} = r, board_id) do
    case Map.fetch(r.boards, board_id) do
      {:ok, board} ->
        Admission.active_device?(Log.gate().restaurant, r.chapter, r.merchant, board.signer)

      :error ->
        false
    end
  end

  defp put_menu(r, menu, revision) do
    merchant = r.merchant
    currency = r.currency
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

    display = Enum.map(menu, &Map.take(&1, [:id, :name, :discount_minor]))
    %{r | catalog: catalog, menu: display, menu_revision: revision}
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
