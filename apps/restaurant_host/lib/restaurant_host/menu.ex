defmodule RestaurantHost.Menu do
  @moduledoc """
  The storefront's menu, read from the Log (Eatsbot decommission D6): the
  governance-signed `RestaurantMenuItemPutV1` facts for this restaurant's
  chapter and merchant (`RestaurantCore.Menu`), as a `CommerceCore.Catalog`
  in the restaurant's currency. Nothing is cached, so an admitted edit is on
  the next page render and the next price, without a restart.

  Admission refuses whatever the catalog would refuse, so every admitted item
  converts; items priced in another currency are left out.
  """

  alias CommerceCore.Catalog
  alias CoopSubstrate.Log
  alias RestaurantCore.Admission
  alias RestaurantHost.Restaurant

  @doc "`%{catalog, listing}`: the catalog, and its published items in menu order."
  def current(%Restaurant{} = r),
    do: from(Admission.menu(Log.gate().restaurant, r.chapter, r.merchant), r.merchant, r.currency)

  @doc "The catalog for a `RestaurantCore.Menu`, for one merchant and currency."
  def from(%{items: items}, merchant, currency) do
    code = Atom.to_string(currency)

    ours =
      items
      |> Map.values()
      |> Enum.filter(&(&1.currency == code))
      |> Enum.sort_by(&{&1.name, &1.id})

    {:ok, empty} = Catalog.new(merchant)

    catalog =
      ours
      |> Enum.with_index()
      |> Enum.reduce(empty, fn {item, version}, catalog ->
        {:ok, catalog} = Catalog.put(catalog, merchant, version, product(item, currency))
        catalog
      end)

    %{
      catalog: catalog,
      listing: for(i <- ours, i.visibility == :published, do: %{id: i.id, name: i.name})
    }
  end

  defp product(item, currency),
    do: %{
      id: item.id,
      sku: item.sku,
      visibility: item.visibility,
      prices: %{currency => Money.from_integer(item.price_minor, currency)},
      discounts: Enum.map(item.discounts, &discount(&1, currency))
    }

  @doc "A money-free `RestaurantCore.Menu` rule as `CommerceCore.Discounts` takes it."
  def discount(rule, currency) do
    Map.new(rule, fn
      {:rate, rate} -> {:rate, Decimal.new(rate)}
      {:price_minor, p} -> {:price, Money.from_integer(p, currency)}
      {:amount_minor, a} -> {:amount, Money.from_integer(a, currency)}
      other -> other
    end)
  end
end
