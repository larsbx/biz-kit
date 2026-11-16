defmodule ScfCore.Money do
  @moduledoc "Dinar algérien amounts as integer centimes (1 DA = 100 centimes)."

  @doc ~S|Formats centimes as `"1 234 567,89 DA"`.|
  def format(centimes) when is_integer(centimes) do
    sign = if centimes < 0, do: "-", else: ""
    abs = abs(centimes)

    "#{sign}#{group(div(abs, 100))},#{abs |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")} DA"
  end

  @doc """
  Parses a positive amount typed in dinars — `"1 234,56"`, `"1234.5"`, an
  optional `DA` suffix — into centimes. Thousands may be grouped by spaces
  (incl. no-break) in threes; at most two decimals. Anything else is refused,
  never rounded or guessed.
  """
  def parse(text) when is_binary(text) do
    case Regex.run(
           ~r/\A(\d{1,3}(?:[ \x{00A0}\x{202F}]\d{3})*|\d+)(?:[,.](\d{1,2}))?(?:\s*DA)?\z/u,
           String.trim(text)
         ) do
      [_, units | decimals] ->
        cents = decimals |> List.first("") |> String.pad_trailing(2, "0")

        {:ok,
         String.to_integer(String.replace(units, ~r/\D/u, "")) * 100 + String.to_integer(cents)}

      nil ->
        {:error, :invalid_amount}
    end
  end

  def parse(_), do: {:error, :invalid_amount}

  defp group(n),
    do:
      n
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1 ")
      |> String.reverse()
end
