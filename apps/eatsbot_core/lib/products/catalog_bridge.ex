defmodule EatsbotCore.Products.CatalogBridge do
  @moduledoc """
  Read-only adapter for isolated Eatsbot product/variant projections.

  Does not change Eatsbot's Ash resources, repositories, GraphQL API or writer.
  Home and merchant scope come from a host-bound isolated source and current
  authority, never a label inferred from the imported Product resource.
  """

  alias CommerceCore.{Catalog, Ownership}

  @doc "Merchant labels alone cannot establish ownership of an unscoped legacy row."
  @deprecated "Use preview/3 with a host-bound isolated source and a current grant"
  def preview(_merchant, _product), do: {:error, :forbidden}

  @doc """
  Load a product only after the isolated source and current host authority match.

  `source` is deployment configuration binding ONE isolated legacy store to a
  home/merchant/source ID. `trusted` comes from the host's current grant resolver.
  `load_product` is a host-owned zero-arity function bound to that exact store;
  it returns `{:ok, loaded_product}`. Neither argument may come from a client.
  Shared stores are refused: legacy rows cannot prove their merchant ownership.
  This is read-only candidate projection, never writer admission or a DB policy.
  """
  def preview(source, trusted, load_product) when is_function(load_product, 0) do
    with :ok <- authorize_source(source, trusted),
         {:ok, product} <- load_product.(),
         {:ok, state} <- Catalog.new(source),
         {:ok, item} <- normalize_product(product),
         {:ok, state} <- Catalog.put(state, source, 0, item) do
      {:ok, state}
    end
  end

  def preview(_, _, _), do: {:error, :forbidden}

  defp authorize_source(
         %{mode: :isolated_runtime, source_id: id} = source,
         %{granted: true, operation: :catalog_read, source_id: id, principal: principal} = trusted
       ) do
    if Ownership.id?(id) and Ownership.id?(principal),
      do: Ownership.check(source, trusted),
      else: {:error, :forbidden}
  end

  defp authorize_source(_, _), do: {:error, :forbidden}

  defp normalize_product(product) when is_map(product) do
    with {:ok, prices} <- price_map(Map.get(product, :prices)),
         {:ok, variants} <- variant_maps(Map.get(product, :variants)) do
      {:ok,
       %{
         id: Map.get(product, :id),
         sku: Map.get(product, :sku),
         visibility: state(Map.get(product, :state)),
         prices: prices,
         variants: variants,
         tax_context: "eatsbot-unspecified"
       }}
    else
      _ -> {:error, :unloaded_catalog_projection}
    end
  end

  defp normalize_product(_), do: {:error, :unloaded_catalog_projection}

  defp variant_maps(variants) when is_list(variants) do
    Enum.reduce_while(variants, {:ok, []}, fn variant, {:ok, acc} ->
      prices = if is_map(variant), do: Map.get(variant, :prices)

      case price_map(prices) do
        {:ok, prices} ->
          {:cont,
           {:ok,
            [%{id: Map.get(variant, :id), sku: Map.get(variant, :sku), prices: prices} | acc]}}

        _ ->
          {:halt, {:error, :unloaded_catalog_projection}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp variant_maps(_), do: {:error, :unloaded_catalog_projection}

  defp price_map(prices) when is_list(prices) and prices != [] do
    valid? = Enum.all?(prices, &match?(%{money: %Money{}}, &1))

    if valid? do
      currencies = Enum.map(prices, fn %{money: value} -> value.currency end)

      if Enum.uniq(currencies) == currencies,
        do: {:ok, Map.new(prices, fn %{money: value} -> {value.currency, value} end)},
        else: {:error, :duplicate_currency_price}
    else
      {:error, :unloaded_catalog_projection}
    end
  end

  defp price_map(_), do: {:error, :unloaded_catalog_projection}

  defp state(:enabled), do: :published
  defp state(:hidden), do: :hidden
  defp state(_), do: :disabled
end
