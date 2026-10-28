defmodule CommerceCore.CatalogWire do
  @moduledoc """
  V1 untrusted product/price JSON-map decoder for independent domain clients.

  A host must bind the authenticated merchant, grant publishing authority,
  serialize catalog versions and persist accepted changes. This decoder
  produces a candidate for the pure Catalog.put/4 reducer, never a write.
  """

  @schema "bizkit.catalog.product.v1"
  @max_int 9_007_199_254_740_991
  @top_fields ~w(schema merchant expected_version id sku visibility prices variants tax_context)
  @variant_fields ~w(id sku prices)
  @price_fields ~w(currency minor_units)
  @currencies %{"USD" => :USD, "EUR" => :EUR, "CLP" => :CLP}
  @visibility %{"published" => :published, "hidden" => :hidden, "disabled" => :disabled}

  @doc """
  Validate an already decoded JSON object against a trusted host context.

  `trusted` must contain `:merchant` and `:allow_publish` from the
  host's verified grants. A client-supplied merchant ID cannot authorize an
  operation. Return `%{expected_version: integer(), product: map()}` for
  admission by a serialized, authenticated catalog writer.
  """
  def decode(wire, trusted) when is_map(wire) and is_map(trusted) do
    with :ok <- merchant(wire, trusted),
         :ok <- fields(wire, @top_fields),
         :ok <- schema(wire),
         {:ok, revision} <- nonnegative(wire["expected_version"]),
         :ok <- identifier(wire["id"]),
         :ok <- identifier(wire["sku"]),
         :ok <- identifier(wire["tax_context"]),
         {:ok, visibility} <- lookup(@visibility, wire["visibility"]),
         :ok <- publish_grant(visibility, trusted),
         {:ok, prices} <- price_map(wire["prices"]),
         {:ok, variants} <- variants(wire["variants"]) do
      {:ok,
       %{
         expected_version: revision,
         product: %{
           id: wire["id"],
           sku: wire["sku"],
           visibility: visibility,
           prices: prices,
           variants: variants,
           tax_context: wire["tax_context"]
         }
       }}
    end
  end

  def decode(_, _), do: {:error, :invalid_catalog_command}

  defp merchant(wire, trusted) do
    expected = Map.get(trusted, :merchant)

    if valid_id?(expected) and wire["merchant"] === expected,
      do: :ok,
      else: {:error, :wrong_merchant}
  end

  defp schema(%{"schema" => @schema}), do: :ok
  defp schema(_), do: {:error, :unsupported_catalog_schema}

  defp fields(object, names) when is_map(object) do
    if Enum.sort(Map.keys(object)) == Enum.sort(names),
      do: :ok,
      else: {:error, :invalid_catalog_shape}
  end

  defp fields(_, _), do: {:error, :invalid_catalog_shape}

  defp lookup(options, value) do
    case Map.fetch(options, value) do
      {:ok, known} -> {:ok, known}
      :error -> {:error, :unsupported_catalog_value}
    end
  end

  defp publish_grant(:published, %{allow_publish: true}), do: :ok
  defp publish_grant(:published, _), do: {:error, :publication_not_authorized}
  defp publish_grant(_, _), do: :ok

  defp identifier(s) do
    if valid_id?(s), do: :ok, else: {:error, :invalid_catalog_reference}
  end

  defp valid_id?(s), do: is_binary(s) and byte_size(s) in 1..128

  defp nonnegative(n) when is_integer(n) and n >= 0 and n <= @max_int,
    do: {:ok, n}

  defp nonnegative(_), do: {:error, :invalid_catalog_number}

  defp positive(n) when is_integer(n) and n > 0 and n <= @max_int,
    do: :ok

  defp positive(_), do: {:error, :invalid_catalog_number}

  defp price_map(prices) when is_list(prices) and length(prices) in 1..16 do
    Enum.reduce_while(prices, {:ok, %{}}, fn price, {:ok, acc} ->
      with :ok <- fields(price, @price_fields),
           {:ok, currency} <- lookup(@currencies, price["currency"]),
           :ok <- positive(price["minor_units"]),
           false <- Map.has_key?(acc, currency) do
        {:cont, {:ok, Map.put(acc, currency, Money.from_integer(price["minor_units"], currency))}}
      else
        true -> {:halt, {:error, :duplicate_catalog_currency}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp price_map(_), do: {:error, :invalid_catalog_prices}

  defp variants(items) when is_list(items) and length(items) <= 64 do
    Enum.reduce_while(items, {:ok, []}, fn variant, {:ok, acc} ->
      with :ok <- fields(variant, @variant_fields),
           :ok <- identifier(variant["id"]),
           :ok <- identifier(variant["sku"]),
           {:ok, prices} <- price_map(variant["prices"]) do
        {:cont, {:ok, [%{id: variant["id"], sku: variant["sku"], prices: prices} | acc]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, ordered} -> {:ok, Enum.reverse(ordered)}
      error -> error
    end
  end

  defp variants(_), do: {:error, :invalid_catalog_variants}
end
