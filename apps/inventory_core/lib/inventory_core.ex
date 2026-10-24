defmodule InventoryCore do
  import Kernel, except: [apply: 3]

  @moduledoc """
  Pure, replayable, scoped inventory command rules.

  A host must serialize authorization, expected-version checks and committed
  event append. This module does **not** implement an inventory database,
  signed ledger, scheduler, authorization service or physical stock counter.
  Quantities are exact integer minor units of one declared stock unit.
  """

  @doc "Initialize a single merchant/item/unit stock aggregate."
  def new(merchant, item, unit)
      when is_binary(merchant) and byte_size(merchant) > 0 and
             is_binary(item) and byte_size(item) > 0 and
             is_binary(unit) and byte_size(unit) > 0 do
    {:ok,
     %{
       merchant: merchant,
       item: item,
       unit: unit,
       version: 0,
       locations: %{},
       reservations: %{},
       seen: %{},
       expiry_watermark: 0
     }}
  end

  def new(_, _, _), do: {:error, :invalid_stock_scope}

  @doc "Read unreserved on-hand quantity at a location."
  def available(state, merchant, location) do
    with :ok <- scoped(state, merchant), :ok <- identifier(location) do
      on_hand = Map.get(state.locations, location, 0)
      held = holds(state.reservations, location)
      {:ok, on_hand - held}
    end
  end

  @doc """
  Apply an already-authorized command with optimistic version and stable ID.

  Exact duplicate command IDs return `{:ok, state, :duplicate}`, even after
  later changes. Reusing an ID for different content is always refused.
  """
  def apply(state, merchant, %{id: id, expected_version: expected, op: _} = command) do
    with :ok <- scoped(state, merchant), :ok <- identifier(id) do
      case Map.get(state.seen, id) do
        ^command ->
          {:ok, state, :duplicate}

        nil ->
          with :ok <- version(state.version, expected),
               {:ok, updated} <- transition(state, command) do
            next = %{
              updated
              | version: state.version + 1,
                seen: Map.put(state.seen, id, command)
            }

            {:ok, next, :accepted}
          end

        _ ->
          {:error, :idempotency_conflict}
      end
    end
  end

  def apply(_, _, _), do: {:error, :invalid_command}

  @doc "Fold an admitted command sequence, rejecting the first invalid event."
  def replay(initial, merchant, commands) when is_list(commands) do
    Enum.reduce_while(commands, {:ok, initial}, fn command, {:ok, state} ->
      case apply(state, merchant, command) do
        {:ok, next, _} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  def replay(_, _, _), do: {:error, :invalid_commands}

  @doc "A deterministic invariant check, suitable for reconciliation."
  def check(state, merchant) do
    with :ok <- scoped(state, merchant) do
      valid =
        Enum.all?(state.locations, fn {location, amount} ->
          is_integer(amount) and amount >= 0 and
            amount >= holds(state.reservations, location)
        end)

      if valid, do: :ok, else: {:error, :stock_invariant_violated}
    end
  end

  defp scoped(%{merchant: merchant}, merchant), do: :ok
  defp scoped(%{merchant: _}, _), do: {:error, :wrong_merchant}
  defp scoped(_, _), do: {:error, :invalid_stock_state}

  defp version(expected, expected), do: :ok
  defp version(_, _), do: {:error, :stale_stock_version}

  defp identifier(v) when is_binary(v) and byte_size(v) in 1..128, do: :ok
  defp identifier(_), do: {:error, :invalid_identifier}

  defp quantity(q) when is_integer(q) and q > 0, do: :ok
  defp quantity(_), do: {:error, :invalid_quantity}

  defp holds(reservations, location) do
    reservations
    |> Map.values()
    |> Enum.filter(&(&1.location == location and &1.status == :active))
    |> Enum.reduce(0, fn r, acc -> acc + r.remaining end)
  end

  defp ensure_available(state, location, amount) do
    case available(state, state.merchant, location) do
      {:ok, n} when n >= amount -> :ok
      {:ok, _} -> {:error, :insufficient_available}
      error -> error
    end
  end

  defp transition(state, %{op: :receive, location: location, quantity: q}) do
    with :ok <- identifier(location), :ok <- quantity(q) do
      {:ok, %{state | locations: Map.update(state.locations, location, q, &(&1 + q))}}
    end
  end

  defp transition(state, %{
         op: :reserve,
         location: location,
         quantity: q,
         reservation_id: ref,
         expires_at_ms: expires
       }) do
    with :ok <- identifier(location),
         :ok <- identifier(ref),
         :ok <- quantity(q),
         true <- is_integer(expires) and expires > state.expiry_watermark,
         false <- Map.has_key?(state.reservations, ref),
         :ok <- ensure_available(state, location, q) do
      r = %{location: location, remaining: q, status: :active, expires_at_ms: expires}
      {:ok, %{state | reservations: Map.put(state.reservations, ref, r)}}
    else
      true -> {:error, :reservation_exists}
      false -> {:error, :invalid_expiry}
      {:error, _} = error -> error
      _ -> {:error, :invalid_expiry}
    end
  end

  defp transition(state, %{op: :commit, reservation_id: ref, quantity: q}) do
    with :ok <- identifier(ref),
         :ok <- quantity(q),
         {:ok, r} <- reservation(state, ref),
         true <- r.status == :active and q <= r.remaining do
      updated = %{r | remaining: r.remaining - q}
      updated = if updated.remaining == 0, do: %{updated | status: :committed}, else: updated

      {:ok,
       %{
         state
         | reservations: Map.put(state.reservations, ref, updated),
           locations: Map.update!(state.locations, r.location, &(&1 - q))
       }}
    else
      false -> {:error, :reservation_not_active}
      {:error, _} = error -> error
    end
  end

  defp transition(state, %{op: :release, reservation_id: ref}) do
    with :ok <- identifier(ref),
         {:ok, %{status: :active} = r} <- reservation(state, ref) do
      {:ok, %{state | reservations: Map.put(state.reservations, ref, %{r | status: :released})}}
    else
      {:ok, _} -> {:error, :reservation_not_active}
      {:error, _} = error -> error
    end
  end

  defp transition(state, %{op: :transfer, from: from, to: to, quantity: q}) do
    with :ok <- identifier(from),
         :ok <- identifier(to),
         true <- from != to,
         :ok <- quantity(q),
         :ok <- ensure_available(state, from, q) do
      locations =
        state.locations
        |> Map.update!(from, &(&1 - q))
        |> Map.update(to, q, &(&1 + q))

      {:ok, %{state | locations: locations}}
    else
      false -> {:error, :same_location}
      {:error, _} = error -> error
    end
  end

  defp transition(state, %{
         op: :adjust,
         location: location,
         delta: delta,
         reason: reason,
         approved: true
       }) do
    with :ok <- identifier(location),
         true <- is_integer(delta) and delta != 0,
         :ok <- identifier(reason),
         :ok <- if(delta < 0, do: ensure_available(state, location, -delta), else: :ok) do
      {:ok,
       %{
         state
         | locations: Map.update(state.locations, location, delta, &(&1 + delta))
       }}
    else
      false -> {:error, :invalid_delta}
      {:error, _} = error -> error
    end
  end

  defp transition(state, %{op: :expire, at_ms: now})
       when is_integer(now) and now >= 0 do
    if now < state.expiry_watermark do
      {:error, :nonmonotone_clock}
    else
      remaining =
        Map.new(state.reservations, fn {id, r} ->
          if r.status == :active and r.expires_at_ms <= now,
            do: {id, %{r | status: :expired}},
            else: {id, r}
        end)

      {:ok, %{state | reservations: remaining, expiry_watermark: now}}
    end
  end

  defp transition(_, _), do: {:error, :invalid_or_unauthorized_operation}

  defp reservation(state, ref) do
    case Map.fetch(state.reservations, ref) do
      {:ok, r} -> {:ok, r}
      :error -> {:error, :unknown_reservation}
    end
  end
end
