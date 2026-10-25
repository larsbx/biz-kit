defmodule FederationService.JSON do
  @moduledoc "Bounded plain JSON; no JSON-LD dereferencing or context expansion."
  def decode(bytes) when is_binary(bytes) and byte_size(bytes) <= 65_536 do
    # Bound structural nesting before invoking the JSON parser. Strings do not
    # contribute nesting, including escaped quotation marks.
    with true <- depth(bytes, 0, false, false),
         {:ok, ordered} <- Jason.decode(bytes, objects: :ordered_objects),
         {:ok, value} <- normalize(ordered),
         true <- is_map(value) do
      {:ok, value}
    else
      _ -> {:error, :invalid_json}
    end
  end

  def decode(_), do: {:error, :invalid_json}

  defp normalize(%Jason.OrderedObject{values: pairs}) do
    if length(pairs) == length(Enum.uniq_by(pairs, &elem(&1, 0))) do
      Enum.reduce_while(pairs, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
        case normalize(v) do
          {:ok, n} -> {:cont, {:ok, Map.put(acc, k, n)}}
          error -> {:halt, error}
        end
      end)
    else
      {:error, :duplicate_json_key}
    end
  end

  defp normalize(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn v, {:ok, acc} ->
      case normalize(v) do
        {:ok, n} -> {:cont, {:ok, [n | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp normalize(value), do: {:ok, value}

  defp depth(<<>>, 0, false, _), do: true
  defp depth(<<>>, _, _, _), do: false
  defp depth(_, n, _, _) when n > 16 or n < 0, do: false
  defp depth(<<_, rest::binary>>, n, true, true), do: depth(rest, n, true, false)
  defp depth(<<92, rest::binary>>, n, true, false), do: depth(rest, n, true, true)
  defp depth(<<34, rest::binary>>, n, s, false), do: depth(rest, n, not s, false)

  defp depth(<<c, rest::binary>>, n, false, false) when c in [123, 91],
    do: depth(rest, n + 1, false, false)

  defp depth(<<c, rest::binary>>, n, false, false) when c in [125, 93],
    do: depth(rest, n - 1, false, false)

  defp depth(<<_, rest::binary>>, n, s, e), do: depth(rest, n, s, e)
end
