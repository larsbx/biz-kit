defmodule MarketingCore.Redemption do
  @moduledoc """
  Pure, merchant-scoped, one-use redemption and commission *candidate*.

  Salvages Eatsbot's check-in rate snapshot and guarded redemption but uses
  integer minor units and an explicit parts-per-million commission rate.
  Rounding is half up, **not proved equivalent** to legacy Money/Decimal.
  Host-side authorization, persisted source evidence, consent and any actual
  financial obligations/settlement are separate.
  """

  @scale 1_000_000

  @spec new(String.t(), String.t(), String.t(), DateTime.t(), boolean(), non_neg_integer()) ::
          {:ok, map()} | {:error, atom()}
  def new(merchant, visit_id, code, %DateTime{} = checked_in_at, attributed?, rate_ppm) do
    with :ok <- reference(merchant),
         :ok <- reference(visit_id),
         :ok <- reference(code),
         true <- is_boolean(attributed?),
         true <- is_integer(rate_ppm) and rate_ppm in 0..@scale do
      {:ok,
       %{
         merchant: merchant,
         visit_id: visit_id,
         code: code,
         checked_in_at: checked_in_at,
         attributed?: attributed?,
         rate_ppm: if(attributed?, do: rate_ppm, else: 0),
         phase: :checked_in,
         amount_minor: nil,
         currency: nil,
         commission_minor: nil,
         redeemed_at: nil,
         version: 0,
         seen: %{}
       }}
    else
      _ -> {:error, :invalid_visit}
    end
  end

  def new(_, _, _, _, _, _), do: {:error, :invalid_visit}

  @doc "The cashier class must be authenticated by a trusted platform host."
  def redeem(state, merchant, :cashier, %{id: id, expected_version: revision} = event, window)
      when is_integer(window) and window >= 0 do
    with :ok <- scoped(state, merchant),
         :ok <- reference(id) do
      case Map.fetch(state.seen, id) do
        {:ok, {:cashier, ^event}} ->
          {:ok, state, :duplicate}

        {:ok, _} ->
          {:error, :idempotency_conflict}

        :error ->
          with :ok <- version(state.version, revision),
               {:ok, next} <- transition(state, event, window) do
            {:ok,
             %{
               next
               | version: state.version + 1,
                 seen: Map.put(state.seen, id, {:cashier, event})
             }, :accepted}
          end
      end
    end
  end

  def redeem(_, _, _, _, _), do: {:error, :invalid_redemption}

  def replay(initial, merchant, events, window) when is_list(events) do
    Enum.reduce_while(events, {:ok, initial}, fn event, {:ok, state} ->
      case redeem(state, merchant, :cashier, event, window) do
        {:ok, next, _} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  def replay(_, _, _, _), do: {:error, :invalid_events}

  @doc "Compute a proposed commission with explicit integer half-up rounding."
  def commission_minor(amount_minor, rate_ppm)
      when is_integer(amount_minor) and amount_minor >= 0 and
             is_integer(rate_ppm) and rate_ppm in 0..@scale,
      do: div(amount_minor * rate_ppm + div(@scale, 2), @scale)

  def commission_minor(_, _), do: {:error, :invalid_amount_or_rate}

  defp transition(
         %{phase: :checked_in, code: code, checked_in_at: checked_in_at} = state,
         %{
           op: :redeem,
           code: code,
           amount_minor: amount,
           currency: currency,
           occurred_at: %DateTime{} = occurred_at
         },
         window
       )
       when is_integer(amount) and amount > 0 and is_binary(currency) do
    elapsed = DateTime.diff(occurred_at, checked_in_at, :microsecond)

    cond do
      not Regex.match?(~r/\A[A-Z]{3}\z/, currency) ->
        {:error, :invalid_currency}

      elapsed < 0 or elapsed > window * 1_000_000 ->
        {:error, :redemption_expired}

      true ->
        {:ok,
         %{
           state
           | phase: :redeemed,
             amount_minor: amount,
             currency: currency,
             commission_minor: commission_minor(amount, state.rate_ppm),
             redeemed_at: occurred_at
         }}
    end
  end

  defp transition(%{phase: :redeemed}, _, _), do: {:error, :already_redeemed}
  defp transition(_, _, _), do: {:error, :invalid_redemption}

  defp scoped(%{merchant: owner}, owner), do: :ok
  defp scoped(%{merchant: _}, _), do: {:error, :wrong_merchant}
  defp scoped(_, _), do: {:error, :invalid_state}

  defp version(v, v), do: :ok
  defp version(_, _), do: {:error, :stale_redemption_version}

  defp reference(value) when is_binary(value) and byte_size(value) in 1..128, do: :ok
  defp reference(_), do: {:error, :invalid_reference}
end
