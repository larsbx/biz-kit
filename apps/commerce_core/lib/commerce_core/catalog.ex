defmodule CommerceCore.Catalog do
  @moduledoc """
  Portable, merchant-scoped catalog rules with optimistic revisions.

  This is a pure *candidate projection*, not an authenticated catalog service.
  A production host must authorize the actor, serialize accepted commands and
  persist one authoritative catalog. A caller-provided merchant ID is never
  proof of a grant.
  """

  @visibility [:published, :hidden, :disabled]

  @doc "Create an empty merchant-owned catalog projection."
  def new(merchant) when is_binary(merchant) and byte_size(merchant) > 0 do
    {:ok, %{merchant: merchant, version: 0, products: %{}}}
  end

  def new(_), do: {:error, :invalid_merchant}

  @doc "Validate and replace a product only at the expected catalog revision."
  def put(%{merchant: _, version: _, products: _} = state, merchant, expected, product) do
    with :ok <- scope(state, merchant),
         :ok <- revision(state, expected),
         {:ok, item} <- normalize(product),
         :ok <- unique_skus(state, item) do
      {:ok, %{state | version: expected + 1, products: Map.put(state.products, item.id, item)}}
    end
  end

  def put(_, _, _, _), do: {:error, :invalid_catalog}

  @doc """
  Return an immutable-priced *quote candidate* at a catalog version.

  `modifiers` is the chosen options, as `{group_id, option_id}` pairs in any
  order. The unit price is the variant's price plus each chosen option's delta,
  and each group's minimum and maximum must hold. The caller must bind this
  candidate to checkout validation and commercial admission. This call neither
  reserves inventory nor commits a sale.
  """
  def quote(state, merchant, id, variant_id, currency, modifiers \\ []) do
    with :ok <- scope(state, merchant),
         {:ok, product} <- lookup(state, id),
         :ok <- published(product.visibility),
         {:ok, selected} <- select(product, variant_id),
         {:ok, money} <- price(selected.prices, currency),
         {:ok, chosen} <- selection(modifiers),
         {:ok, deltas} <- modifier_deltas(product.modifier_groups, chosen, currency) do
      {:ok,
       %{
         merchant: state.merchant,
         catalog_version: state.version,
         product_id: product.id,
         variant_id: variant_id,
         sku: selected.sku,
         modifiers: chosen,
         unit_price: Enum.reduce(deltas, money, &Money.add!(&2, &1)),
         tax_context: product.tax_context
       }}
    end
  end

  @doc "Read a product only within the exact same merchant scope."
  def fetch(state, merchant, id) do
    with :ok <- scope(state, merchant), do: lookup(state, id)
  end

  defp scope(%{merchant: expected}, merchant) when expected == merchant, do: :ok
  defp scope(%{merchant: _}, _), do: {:error, :wrong_merchant}
  defp scope(_, _), do: {:error, :invalid_catalog}

  defp revision(%{version: version}, version), do: :ok
  defp revision(_, _), do: {:error, :stale_catalog_revision}

  defp lookup(%{products: products}, id) when is_map(products) do
    case Map.fetch(products, id) do
      {:ok, item} -> {:ok, item}
      :error -> {:error, :unknown_product}
    end
  end

  defp lookup(_, _), do: {:error, :invalid_catalog}

  defp published(:published), do: :ok
  defp published(_), do: {:error, :not_published}

  defp select(product, nil),
    do: {:ok, %{sku: product.sku, prices: product.prices}}

  defp select(product, id) do
    case Enum.find(product.variants, &(&1.id == id)) do
      nil -> {:error, :unknown_variant}
      variant -> {:ok, variant}
    end
  end

  defp price(prices, currency) when is_map(prices) do
    case Map.fetch(prices, currency) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :currency_not_offered}
    end
  end

  defp selection(modifiers) when is_list(modifiers) do
    if Enum.all?(modifiers, &match?({g, o} when is_binary(g) and is_binary(o), &1)),
      do: {:ok, Enum.sort(modifiers)},
      else: {:error, :invalid_modifier_selection}
  end

  defp selection(_), do: {:error, :invalid_modifier_selection}

  # The chosen options' deltas, once every choice names a known option, none is
  # repeated, and every group's count lies within its minimum and maximum.
  defp modifier_deltas(groups, chosen, currency) do
    with :ok <- known_and_distinct(groups, chosen),
         :ok <- counts(groups, chosen) do
      chosen
      |> Enum.map(fn {gid, oid} ->
        option =
          groups
          |> Enum.find(&(&1.id == gid))
          |> Map.fetch!(:options)
          |> Enum.find(&(&1.id == oid))

        case Map.fetch(option.prices, currency) do
          {:ok, delta} -> {:ok, delta}
          :error -> {:error, {:modifier_currency_not_offered, gid, oid}}
        end
      end)
      |> Enum.find(&match?({:error, _}, &1))
      |> case do
        nil -> {:ok, for({gid, oid} <- chosen, do: delta!(groups, gid, oid, currency))}
        error -> error
      end
    end
  end

  defp delta!(groups, gid, oid, currency) do
    group = Enum.find(groups, &(&1.id == gid))
    Enum.find(group.options, &(&1.id == oid)).prices |> Map.fetch!(currency)
  end

  defp known_and_distinct(groups, chosen) do
    known = MapSet.new(for g <- groups, o <- g.options, do: {g.id, o.id})

    case Enum.find(chosen, &(&1 not in known)) do
      {gid, oid} ->
        {:error, {:unknown_modifier, gid, oid}}

      nil ->
        case chosen -- Enum.uniq(chosen) do
          [{gid, oid} | _] -> {:error, {:duplicate_modifier, gid, oid}}
          [] -> :ok
        end
    end
  end

  defp counts(groups, chosen) do
    case Enum.find(groups, fn g ->
           n = Enum.count(chosen, &(elem(&1, 0) == g.id))
           n < g.min or n > g.max
         end) do
      nil -> :ok
      group -> {:error, {:modifier_count, group.id}}
    end
  end

  defp normalize(%{id: id, sku: sku, visibility: visibility, prices: prices} = item) do
    variants = Map.get(item, :variants, [])
    tax_context = Map.get(item, :tax_context, "unspecified")
    modifier_groups = Map.get(item, :modifier_groups, [])

    with :ok <- identifier(id),
         :ok <- identifier(sku),
         true <- visibility in @visibility,
         {:ok, normalized_prices} <- prices_map(prices),
         true <- is_list(variants),
         {:ok, normalized_variants} <- normalize_variants(variants),
         :ok <- unique_variants(normalized_variants),
         true <- is_binary(tax_context) and byte_size(tax_context) > 0,
         {:ok, groups} <- normalize_groups(modifier_groups) do
      {:ok,
       %{
         id: id,
         sku: sku,
         visibility: visibility,
         prices: normalized_prices,
         variants: normalized_variants,
         modifier_groups: groups,
         tax_context: tax_context
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_product}
    end
  end

  defp normalize(_), do: {:error, :invalid_product}

  # A group offers 1+ distinct options, each priced at a non-negative delta in
  # each currency it lists, and allows 0 ≤ min ≤ max choices, 1 ≤ max ≤ options.
  defp normalize_groups(groups) when is_list(groups) do
    normalized = Enum.map(groups, &normalize_group/1)

    if Enum.all?(normalized, &match?({:ok, _}, &1)) and
         unique?(Enum.map(groups, &Map.get(&1, :id))),
       do: {:ok, Enum.map(normalized, &elem(&1, 1))},
       else: {:error, :invalid_modifiers}
  end

  defp normalize_groups(_), do: {:error, :invalid_modifiers}

  defp normalize_group(%{id: id, min: min, max: max, options: [_ | _] = options}) do
    with :ok <- identifier(id),
         true <- is_integer(min) and is_integer(max) and 0 <= min and min <= max,
         true <- 1 <= max and max <= length(options),
         true <- Enum.all?(options, &valid_option?/1),
         true <- unique?(Enum.map(options, & &1.id)) do
      {:ok,
       %{id: id, min: min, max: max, options: Enum.map(options, &Map.take(&1, [:id, :prices]))}}
    else
      _ -> :error
    end
  end

  defp normalize_group(_), do: :error

  defp valid_option?(%{id: id, prices: prices}) when is_map(prices) and map_size(prices) > 0 do
    identifier(id) == :ok and
      Enum.all?(prices, fn
        {currency, %Money{currency: same, amount: amount}} ->
          currency == same and not Decimal.negative?(amount)

        _ ->
          false
      end)
  end

  defp valid_option?(_), do: false

  defp normalize_variants(variants) do
    Enum.reduce_while(variants, {:ok, []}, fn
      %{id: id, sku: sku, prices: prices}, {:ok, acc} ->
        with :ok <- identifier(id),
             :ok <- identifier(sku),
             {:ok, prices} <- prices_map(prices) do
          {:cont, {:ok, [%{id: id, sku: sku, prices: prices} | acc]}}
        else
          error -> {:halt, error}
        end

      _, _ ->
        {:halt, {:error, :invalid_variant}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp prices_map(prices) when is_map(prices) and map_size(prices) > 0 do
    if Enum.all?(prices, fn
         {currency, %Money{currency: same, amount: amount}} ->
           currency == same and Decimal.gt?(amount, 0)

         _ ->
           false
       end) do
      {:ok, prices}
    else
      {:error, :invalid_prices}
    end
  end

  defp prices_map(_), do: {:error, :invalid_prices}

  defp unique_variants(variants) do
    ids = Enum.map(variants, & &1.id)
    skus = Enum.map(variants, & &1.sku)

    if unique?(ids) and unique?(skus),
      do: :ok,
      else: {:error, :duplicate_variant}
  end

  defp unique_skus(state, candidate) do
    all =
      state.products
      |> Map.delete(candidate.id)
      |> Map.values()
      |> Enum.flat_map(&skus/1)

    candidate_skus = skus(candidate)

    if unique?(candidate_skus) and Enum.all?(candidate_skus, &(&1 not in all)),
      do: :ok,
      else: {:error, :duplicate_sku}
  end

  defp skus(item), do: [item.sku | Enum.map(item.variants, & &1.sku)]
  defp unique?(list), do: Enum.uniq(list) == list

  defp identifier(value) when is_binary(value) and byte_size(value) in 1..128,
    do: :ok

  defp identifier(_), do: {:error, :invalid_identifier}
end
