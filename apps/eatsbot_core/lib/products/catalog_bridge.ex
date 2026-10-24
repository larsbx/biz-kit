defmodule EatsbotCore.Products.CatalogBridge do
  @moduledoc """
  Read-only adapter for already-loaded Eatsbot product/variant projections.

  Does not change Eatsbot's Ash resources, repositories, public API or writer.
  Merchant scope comes from a separately authorized context, not a field
  inferred from the imported Product resource.
  """

  alias CommerceCore.Catalog

  @doc "Project a loaded Eatsbot product into a portable candidate catalog."
  def preview(merchant, product) when is_map(product) do
    with {:ok, state} <- Catalog.new(merchant),
         {:ok, item} <- normalize_product(product),
         {:ok, state} <- Catalog.put(state, merchant, 0, item) do
      {:ok, state}
    end
  end

  def preview(_, _), do: {:error, :invalid_product}

  defp normalize_product(product) do
    with {:ok, prices} <- price_map(Map.get(product, :prices)),
         {:ok, variants} <- variant_maps(Map.get(product, :variants, [])) do
      {:ok,
       %{
         id: product.id,
         sku: product.sku,
         visibility: state(Map.get(product, :state)),
         prices: prices,
         variants: variants,
         tax_context: "eatsbot-unspecified"
       }}
    else
      _ -> {:error, :unloaded_catalog_projection}
    end
  end

  defp variant_maps(variants) when is_list(variants) do
    Enum.reduce_while(variants, {:ok, []}, fn variant, {:ok, acc} ->
      case price_map(Map.get(variant, :prices)) do
        {:ok, prices} ->
          {:cont, {:ok, [%{id: variant.id, sku: variant.sku, prices: prices} | acc]}}

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
    if Enum.all?(prices, &match?(%{money: %Money{}}, &1)) do
      {:ok, Map.new(prices, fn %{money: value} -> {value.currency, value} end)}
    else
      {:error, :unloaded_catalog_projection}
    end
  end

  defp price_map(_), do: {:error, :unloaded_catalog_projection}

  defp state(:enabled), do: :published
  defp state(:hidden), do: :hidden
  defp state(_), do: :disabled
end
