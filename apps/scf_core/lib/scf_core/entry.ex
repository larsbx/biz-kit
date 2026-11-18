defmodule ScfCore.Entry do
  @moduledoc """
  An écriture comptable: a dated, journal-coded, document-backed set of lines
  with Σ débit = Σ crédit. Amounts are positive integers in centimes (DZD).

  Every entry must cite its pièce justificative (Loi 07-11, art. 18); `new/1`
  reports every violation at once rather than the first.
  """
  alias ScfCore.Chart

  @enforce_keys [:id, :journal, :date, :piece, :lines]
  defstruct [:id, :journal, :date, :piece, :lines, label: ""]

  @type side :: :debit | :credit
  @type line :: {side, Chart.account(), pos_integer}
  @type t :: %__MODULE__{
          id: String.t(),
          journal: String.t(),
          date: Date.t(),
          piece: String.t(),
          label: String.t(),
          lines: [line]
        }

  @spec new(map) :: {:ok, t} | {:error, [term]}
  def new(attrs) do
    lines = Map.get(attrs, :lines, [])

    case errors(attrs, lines) do
      [] ->
        {:ok,
         struct!(__MODULE__, Map.take(attrs, [:id, :journal, :date, :piece, :label, :lines]))}

      errs ->
        {:error, errs}
    end
  end

  @doc "Σ of the entry's lines on `side`."
  def total(%{lines: lines}, side), do: sum(lines, side)

  defp errors(attrs, lines) do
    header = [
      {:missing_id, present?(attrs[:id])},
      {:missing_piece, present?(attrs[:piece])},
      {:invalid_journal, is_binary(attrs[:journal]) and attrs[:journal] =~ ~r/^[A-Z]{2,4}$/},
      {:invalid_date, match?(%Date{}, attrs[:date])},
      {:fewer_than_two_lines, is_list(lines) and length(lines) >= 2}
    ]

    for({err, false} <- header, do: err) ++ line_errors(lines) ++ balance_errors(lines)
  end

  defp line_errors(lines) when is_list(lines) do
    Enum.flat_map(lines, fn
      {side, a, m} when side in [:debit, :credit] ->
        [
          {{:invalid_account, a}, Chart.account?(a)},
          {{:non_positive_amount, a}, is_integer(m) and m > 0}
        ]
        |> for_false()

      other ->
        [{:invalid_line, other}]
    end)
  end

  defp line_errors(_), do: [:invalid_lines]

  # Only meaningful once every line is well-formed.
  defp balance_errors(lines) when is_list(lines) do
    with true <-
           Enum.all?(lines, &match?({s, _, m} when s in [:debit, :credit] and is_integer(m), &1)),
         {d, c} when d != c <- {sum(lines, :debit), sum(lines, :credit)} do
      [{:unbalanced, d, c}]
    else
      _ -> []
    end
  end

  defp balance_errors(_), do: []

  defp for_false(checks), do: for({err, false} <- checks, do: err)
  defp sum(lines, side), do: for({^side, _, m} <- lines, reduce: 0, do: (acc -> acc + m))
  defp present?(s), do: is_binary(s) and String.trim(s) != ""
end
