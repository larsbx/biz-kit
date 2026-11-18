defmodule RestaurantCore.Menu do
  @moduledoc """
  The signed pickup menu wire format. Amounts are opaque integer minor units.
  A publication replaces the whole menu at the next revision.
  """

  def valid?(currency, items) when is_binary(currency) and is_list(items) do
    Regex.match?(~r/\A[A-Z]{3}\z/, currency) and length(items) <= 200 and
      Enum.all?(items, &item?/1) and unique?(items, "id") and unique?(items, "sku")
  end

  def valid?(_, _), do: false

  defp item?(%{"id" => id, "sku" => sku, "name" => name, "price_minor" => price} = item) do
    discount = Map.get(item, "discount_minor", 0)

    Map.keys(item) -- ~w(id sku name price_minor discount_minor) == [] and
      identifier?(id) and identifier?(sku) and is_binary(name) and byte_size(name) in 1..160 and
      String.valid?(name) and String.trim(name) != "" and
      is_integer(price) and price in 1..100_000_000 and
      is_integer(discount) and discount in 0..price
  end

  defp item?(_), do: false

  defp identifier?(id),
    do: is_binary(id) and byte_size(id) in 1..64 and Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, id)

  defp unique?(items, key), do: length(Enum.uniq_by(items, & &1[key])) == length(items)
end
