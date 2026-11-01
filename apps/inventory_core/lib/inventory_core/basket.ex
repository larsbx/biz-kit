defmodule InventoryCore.Basket do
  @moduledoc """
  Deterministic, all-or-refuse *preflight* for a multi-item stock reservation.

  The host supplies trusted merchant, recipe requirements, stock snapshots,
  and a basket ID. This pure function checks each InventoryCore aggregate
  but does not append, persist, or lock any of them. A successful preview
  must never be presented as stock reserved or an order accepted.

  A real host must verify and atomically commit **all** commands under their
  expected revisions, or commit none, using its one authoritative stock
  admission service. Never execute this list as independent best-effort
  writes: a failed later ingredient would otherwise leave orphaned holds.
  """

  @max_minor 9_007_199_254_740_991
  @max_requirements 64

  @type requirement :: %{item: String.t(), unit: String.t(), per_unit: pos_integer()}

  @doc """
  Preview a reservation for `count` finished products at `location`.

  Each requirement describes one stock item and its *exact* unit of measure.
  The returned command IDs and reservation IDs are the host-provided basket
  ID within distinct per-item stock aggregates. A trusted admission host
  must additionally enforce globally unique basket IDs where required.
  """
  @spec plan(map(), String.t(), String.t(), String.t(), pos_integer(), [requirement()],
          non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def plan(stocks, merchant, location, basket_id, count, requirements, expires_at_ms)
      when is_map(stocks) do
    with :ok <- identifiers(merchant, location, basket_id),
         :ok <- positive(count),
         :ok <- timestamp(expires_at_ms),
         :ok <- requirements(requirements) do
      ordered = Enum.sort_by(requirements, & &1.item)

      Enum.reduce_while(ordered, {:ok, []}, fn requirement, {:ok, acc} ->
        case proposal(stocks, merchant, location, basket_id, count, requirement, expires_at_ms) do
          {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
          {:error, reason} -> {:halt, {:error, {requirement.item, reason}}}
        end
      end)
      |> case do
        {:ok, reversed} ->
          {:ok,
           %{
             kind: :unsigned_inventory_basket,
             merchant: merchant,
             basket_id: basket_id,
             commands: Enum.reverse(reversed)
           }}

        {:error, _} = error ->
          error
      end
    end
  end

  def plan(_, _, _, _, _, _, _), do: {:error, :invalid_stock_snapshots}

  defp proposal(stocks, merchant, location, basket_id, count, requirement, expires) do
    %{item: item, unit: unit, per_unit: per_unit} = requirement
    amount = count * per_unit

    cond do
      amount > @max_minor ->
        {:error, :quantity_overflow}

      true ->
        case Map.fetch(stocks, item) do
          {:ok,
           %{
             merchant: ^merchant,
             item: ^item,
             unit: ^unit,
             version: version,
             locations: locations,
             reservations: reservations,
             seen: seen,
             expiry_watermark: watermark
           } = stock}
          when is_integer(version) and version >= 0 and is_map(locations) and
                 is_map(reservations) and is_map(seen) and is_integer(watermark) and
                 watermark >= 0 ->
            command = %{
              id: basket_id,
              expected_version: stock.version,
              op: :reserve,
              location: location,
              quantity: amount,
              reservation_id: basket_id,
              expires_at_ms: expires
            }

            case InventoryCore.apply(stock, merchant, command) do
              {:ok, _candidate_state, :accepted} ->
                {:ok,
                 %{
                   item: item,
                   unit: unit,
                   expected_version: stock.version,
                   command: command
                 }}

              {:ok, _state, :duplicate} ->
                {:error, :already_reserved}

              {:error, reason} ->
                {:error, reason}
            end

          {:ok, _} ->
            {:error, :stock_scope_mismatch}

          :error ->
            {:error, :unknown_stock}
        end
    end
  end

  defp identifiers(merchant, location, basket_id) do
    if Enum.all?([merchant, location, basket_id], &identifier?/1),
      do: :ok,
      else: {:error, :invalid_basket_scope}
  end

  defp requirements(items) when is_list(items) do
    cond do
      items == [] or length(items) > @max_requirements ->
        {:error, :invalid_basket_requirements}

      not Enum.all?(items, &requirement?/1) ->
        {:error, :invalid_basket_requirements}

      length(Enum.uniq_by(items, & &1.item)) != length(items) ->
        {:error, :duplicate_basket_item}

      true ->
        :ok
    end
  end

  defp requirements(_), do: {:error, :invalid_basket_requirements}

  defp requirement?(%{item: item, unit: unit, per_unit: per_unit} = requirement) do
    map_size(requirement) == 3 and identifier?(item) and identifier?(unit) and
      positive?(per_unit)
  end

  defp requirement?(_), do: false

  defp positive(n), do: if(positive?(n), do: :ok, else: {:error, :invalid_basket_count})

  defp positive?(n), do: is_integer(n) and n > 0 and n <= @max_minor

  defp timestamp(n) when is_integer(n) and n >= 0 and n <= @max_minor, do: :ok
  defp timestamp(_), do: {:error, :invalid_reservation_expiry}

  defp identifier?(x), do: is_binary(x) and byte_size(x) in 1..128
end
