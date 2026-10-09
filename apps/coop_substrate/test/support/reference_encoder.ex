defmodule CoopSubstrate.ReferenceEncoder do
  @moduledoc """
  Pure-Elixir **reference** implementation of `CoopEventCanonicalV1`
  (SUBSTRATE.md §1). Test-only. Written independently of the Rust NIF; the
  cross-implementation property tests assert byte parity between the two on
  arbitrary generated terms and on the committed vectors.

  Do not use in production paths — `CoopSubstrate.Canonical` (NIF) is the
  production encoder.
  """

  alias CoopSubstrate.Constants

  @spec encode(term()) :: {:ok, binary()} | {:error, atom()}
  def encode(term) do
    with {:ok, iodata} <- enc(term, 0) do
      bytes = IO.iodata_to_binary(iodata)

      if byte_size(bytes) > Constants.max_canonical_bytes() do
        {:error, :too_large}
      else
        {:ok, bytes}
      end
    end
  end

  @spec hash(term()) :: {:ok, binary()} | {:error, atom()}
  def hash(term) do
    with {:ok, bytes} <- encode(term), do: {:ok, :crypto.hash(:sha256, bytes)}
  end

  # -- encoding ---------------------------------------------------------------

  defp enc(_term, depth) when depth > 32, do: {:error, :too_deep}

  defp enc(n, _depth) when is_integer(n) do
    cond do
      n >= 0 and n < 18_446_744_073_709_551_616 and n <= 9_223_372_036_854_775_807 ->
        {:ok, head(0, n)}

      n < 0 and n >= -9_223_372_036_854_775_808 ->
        {:ok, head(1, -1 - n)}

      true ->
        {:error, :int_out_of_range}
    end
  end

  defp enc(f, _depth) when is_float(f), do: {:error, :float_forbidden}
  defp enc(true, _depth), do: {:ok, <<0xF5>>}
  defp enc(false, _depth), do: {:ok, <<0xF4>>}
  defp enc(nil, _depth), do: {:ok, <<0xF6>>}

  defp enc(s, _depth) when is_binary(s) do
    if String.valid?(s) do
      {:ok, [head(3, byte_size(s)), s]}
    else
      {:error, :invalid_utf8}
    end
  end

  defp enc({:bytes, b}, _depth) when is_binary(b), do: {:ok, [head(2, byte_size(b)), b]}
  defp enc({:bytes, _}, _depth), do: {:error, :bad_bytes_wrapper}

  defp enc(list, depth) when is_list(list) do
    Enum.reduce_while(list, {:ok, [head(4, length(list))]}, fn item, {:ok, acc} ->
      case enc(item, depth + 1) do
        {:ok, iodata} -> {:cont, {:ok, [acc, iodata]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp enc(map, depth) when is_map(map) do
    entries =
      Enum.reduce_while(map, {:ok, []}, fn {k, v}, {:ok, acc} ->
        with {:key, true} <- {:key, is_binary(k) and String.valid?(k)},
             {:ok, viodata} <- enc(v, depth + 1) do
          key_bytes = IO.iodata_to_binary([head(3, byte_size(k)), k])
          {:cont, {:ok, [{key_bytes, viodata} | acc]}}
        else
          {:key, false} -> {:halt, {:error, :bad_map_key}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    with {:ok, pairs} <- entries do
      sorted = Enum.sort_by(pairs, fn {kb, _} -> kb end)
      {:ok, [head(5, map_size(map)) | Enum.map(sorted, fn {kb, vb} -> [kb, vb] end)]}
    end
  end

  defp enc(_other, _depth), do: {:error, :forbidden_type}

  defp head(major, arg) when arg < 24, do: <<major::3, arg::5>>
  defp head(major, arg) when arg <= 0xFF, do: <<major::3, 24::5, arg::8>>
  defp head(major, arg) when arg <= 0xFFFF, do: <<major::3, 25::5, arg::16>>
  defp head(major, arg) when arg <= 0xFFFFFFFF, do: <<major::3, 26::5, arg::32>>
  defp head(major, arg), do: <<major::3, 27::5, arg::64>>
end
