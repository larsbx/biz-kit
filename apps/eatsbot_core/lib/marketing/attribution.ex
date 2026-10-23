defmodule EatsbotCore.Marketing.Attribution do
  @moduledoc """
  Pure attribution and revenue-share rules for the marketing agent.

  ## Model

  A customer (subscriber) is notified of a promotion at time `n`. Later they
  scan the NFC/QR sticker at the counter, producing a check-in at time `c`.

      attributed?(n, a, c, W) ⇔ n ≠ nil ∧ n ≤ c ≤ n + W ∧ (a = nil ∨ a < n)

  where `a` is the subscriber's last attributed check-in and `W` the
  attribution window. The last conjunct means each notification credits
  at most one visit.

  On redemption the cashier records the bill amount `m`; the service earns

      commission(m, r) = round(m · r)    with r ∈ [0, 1]

  where `r` is the rate snapshotted at check-in (`0` when not attributed).
  """

  @alphabet ~c"23456789ABCDEFGHJKMNPQRSTUVWXYZ"

  @type seconds :: non_neg_integer()

  @spec attributed?(DateTime.t() | nil, DateTime.t() | nil, DateTime.t(), seconds()) ::
          boolean()
  def attributed?(nil, _last_attributed_at, _checked_in_at, _window), do: false

  def attributed?(notified_at, last_attributed_at, checked_in_at, window) do
    elapsed = DateTime.diff(checked_in_at, notified_at, :second)

    elapsed in 0..window//1 and
      (is_nil(last_attributed_at) or DateTime.before?(last_attributed_at, notified_at))
  end

  @spec commission(Money.t(), Decimal.t()) :: Money.t()
  def commission(%Money{} = amount, rate), do: amount |> Money.mult!(rate) |> Money.round()

  @spec redeemable?(%{status: atom(), checked_in_at: DateTime.t()}, DateTime.t(), seconds()) ::
          boolean()
  def redeemable?(%{status: :checked_in, checked_in_at: checked_in_at}, now, window),
    do: DateTime.diff(now, checked_in_at, :second) in 0..window//1

  def redeemable?(_visit, _now, _window), do: false

  @doc "Total commission per currency."
  @spec statement([%{commission: Money.t() | nil}]) :: %{atom() => Money.t()}
  def statement(visits) do
    visits
    |> Enum.map(& &1.commission)
    |> Enum.reject(&is_nil/1)
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, amounts} -> {currency, Enum.reduce(amounts, &Money.add!/2)} end)
  end

  @doc """
  Cryptographically random code over an alphabet without look-alikes
  (0/O, 1/I/L). Rejection sampling keeps the distribution uniform.
  """
  @spec code(pos_integer()) :: String.t()
  def code(length) do
    n = length(@alphabet)
    limit = 256 - rem(256, n)

    Stream.repeatedly(fn -> :crypto.strong_rand_bytes(length) end)
    |> Stream.flat_map(&:binary.bin_to_list/1)
    |> Stream.filter(&(&1 < limit))
    |> Enum.take(length)
    |> Enum.map(&Enum.at(@alphabet, rem(&1, n)))
    |> List.to_string()
  end
end
