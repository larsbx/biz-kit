defmodule ScfCore.Money do
  @moduledoc "Dinar algérien amounts as integer centimes (1 DA = 100 centimes)."

  @doc ~S|Formats centimes as `"1 234 567,89 DA"`.|
  def format(centimes) when is_integer(centimes) do
    sign = if centimes < 0, do: "-", else: ""
    abs = abs(centimes)

    "#{sign}#{group(div(abs, 100))},#{abs |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")} DA"
  end

  defp group(n),
    do:
      n
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1 ")
      |> String.reverse()
end
