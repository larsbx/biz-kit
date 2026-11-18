defmodule InventoryCore.Menu do
  @moduledoc """
  Menu availability from stock: how many units of a menu item can still be sold at
  a location, given what one unit uses of each tracked stock item.

      sellable = min over requirements of ⌊available(item) / quantity⌋

  `available` is on-hand stock less active reservations, so reserving `sellable`
  units' worth of every requirement succeeds and one more unit's worth does not.
  An item with no requirements uses no tracked stock and is never limited; an item
  none of which can be sold is 86'd. Pure: the host supplies the stock aggregates
  and still reserves stock when an order is admitted.
  """

  @type requirement :: %{item: String.t(), quantity: pos_integer()}

  @doc "How many units can be sold, or `:unlimited` when no stock is tracked."
  @spec sellable([requirement()], %{String.t() => map()}, String.t(), String.t()) ::
          {:ok, non_neg_integer() | :unlimited} | {:error, term()}
  def sellable([], _stocks, _merchant, _location), do: {:ok, :unlimited}

  def sellable(requirements, stocks, merchant, location) do
    with :ok <- valid(requirements) do
      requirements
      |> Enum.reduce_while({:ok, []}, fn %{item: item, quantity: q}, {:ok, acc} ->
        case units(stocks, item, merchant, location) do
          {:ok, available} -> {:cont, {:ok, [div(available, q) | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, counts} -> {:ok, Enum.min(counts)}
        error -> error
      end
    end
  end

  @doc "Whether none can be sold. Fails closed: an item that cannot be checked is 86'd."
  @spec eighty_sixed?([requirement()], %{String.t() => map()}, String.t(), String.t()) ::
          boolean()
  def eighty_sixed?(requirements, stocks, merchant, location) do
    case sellable(requirements, stocks, merchant, location) do
      {:ok, :unlimited} -> false
      {:ok, n} -> n == 0
      {:error, _} -> true
    end
  end

  defp units(stocks, item, merchant, location) do
    case Map.fetch(stocks, item) do
      {:ok, %{item: ^item} = stock} -> InventoryCore.available(stock, merchant, location)
      {:ok, _other} -> {:error, {:stock_item_mismatch, item}}
      :error -> {:error, {:unknown_stock, item}}
    end
  end

  defp valid(requirements) when is_list(requirements) do
    if Enum.all?(requirements, &requirement?/1) and
         Enum.uniq_by(requirements, & &1.item) == requirements,
       do: :ok,
       else: {:error, :invalid_requirements}
  end

  defp valid(_), do: {:error, :invalid_requirements}

  defp requirement?(%{item: item, quantity: q}),
    do: is_binary(item) and byte_size(item) in 1..128 and is_integer(q) and q > 0

  defp requirement?(_), do: false
end
