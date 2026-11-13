defmodule ScfCore.Tva do
  @moduledoc """
  Taxe sur la valeur ajoutée.

  Rates are dated law, not constants: 17 % / 7 % from LF 2001, raised to
  19 % / 9 % by LF 2017 from 1 January 2017. Add a row when a Loi de finances
  changes them; never edit a past row.

  Collected TVA is recorded on 4457, deductible TVA on 4456; `g50/3` derives
  the monthly G50 position from those accounts.
  """
  alias ScfCore.Ledger

  # {effective_from, %{class => percent}}, newest first.
  @schedule [
    {~D[2017-01-01], %{normal: 19, reduit: 9}},
    {~D[2001-01-01], %{normal: 17, reduit: 7}}
  ]

  @spec rate(:normal | :reduit, Date.t()) :: {:ok, pos_integer} | {:error, :no_rate_in_force}
  def rate(class, date) do
    case Enum.find(@schedule, fn {from, _} -> Date.compare(date, from) != :lt end) do
      {_, rates} -> Map.fetch(rates, class)
      nil -> {:error, :no_rate_in_force}
    end
  end

  @doc "From a hors-taxe amount; TVA rounded half-up to the centime."
  def from_ht(ht, pct) when is_integer(ht) and ht >= 0 do
    tva = div(2 * ht * pct + 100, 200)
    %{ht: ht, tva: tva, ttc: ht + tva}
  end

  @doc "From a toutes-taxes amount; HT rounded half-up, so `ht + tva == ttc` exactly."
  def from_ttc(ttc, pct) when is_integer(ttc) and ttc >= 0 do
    ht = div(2 * ttc * 100 + 100 + pct, 2 * (100 + pct))
    %{ht: ht, tva: ttc - ht, ttc: ttc}
  end

  @doc "G50 TVA position for the period: payable `due`, or `credit` to carry forward."
  def g50(ledger, from, to) do
    mv = Ledger.movements(ledger, from: from, to: to)
    collectee = net(mv, "4457", fn {d, c} -> c - d end)
    deductible = net(mv, "4456", fn {d, c} -> d - c end)
    diff = collectee - deductible
    %{collectee: collectee, deductible: deductible, due: max(diff, 0), credit: max(-diff, 0)}
  end

  defp net(mv, prefix, f),
    do: for({a, dc} <- mv, String.starts_with?(a, prefix), reduce: 0, do: (acc -> acc + f.(dc)))
end
