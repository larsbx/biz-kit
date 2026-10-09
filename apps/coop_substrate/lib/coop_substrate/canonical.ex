defmodule CoopSubstrate.Canonical do
  @moduledoc """
  Production encoder for `CoopEventCanonicalV1` (SUBSTRATE.md §1), implemented
  as a Rust NIF (`native/canonical_v1`).

  Logical term model:

    * integers in -2^63..2^63-1
    * UTF-8 strings (plain binaries; must be valid UTF-8)
    * byte strings as `{:bytes, binary}`
    * booleans, `nil`
    * lists
    * maps with string keys only

  Floats, CBOR tags, atoms (other than booleans/nil), structs and any other
  term are rejected. Encoding is deterministic: logically equal terms encode
  to identical bytes regardless of construction order.
  """

  use Rustler, otp_app: :coop_substrate, crate: "canonical_v1"

  @type reason ::
          :float_forbidden
          | :int_out_of_range
          | :invalid_utf8
          | :bad_map_key
          | :forbidden_type
          | :bad_bytes_wrapper
          | :duplicate_map_key
          | :too_large
          | :too_deep

  @spec encode(term()) :: {:ok, binary()} | {:error, reason()}
  def encode(term), do: nif_encode(term)

  @spec encode!(term()) :: binary()
  def encode!(term) do
    case nif_encode(term) do
      {:ok, bytes} -> bytes
      {:error, reason} -> raise ArgumentError, "canonical encoding failed: #{inspect(reason)}"
    end
  end

  @doc "SHA-256 over the canonical encoding of `term`."
  @spec hash(term()) :: {:ok, <<_::256>>} | {:error, reason()}
  def hash(term), do: nif_hash(term)

  @spec hash!(term()) :: <<_::256>>
  def hash!(term) do
    case nif_hash(term) do
      {:ok, digest} -> digest
      {:error, reason} -> raise ArgumentError, "canonical hashing failed: #{inspect(reason)}"
    end
  end

  @doc """
  Strict inverse of `encode/1`. Decodes CBOR, normalizes byte strings to the
  `{:bytes, binary}` wrapper, then **re-encodes and requires byte equality**
  with the input — so every profile rule (sorted keys, shortest forms, no
  tags/floats, UTF-8 validity, size/depth caps) is enforced on the way in
  without duplicating the encoder's logic. Non-canonical bytes never become
  a term.
  """
  @spec decode(binary()) :: {:ok, term()} | {:error, reason() | :non_canonical | :cbor_invalid}
  def decode(bytes) when is_binary(bytes) do
    with {:ok, decoded, ""} <- CBOR.decode(bytes),
         {:ok, term} <- normalize(decoded),
         {:ok, ^bytes} <- reencode(term) do
      {:ok, term}
    else
      {:ok, _term, _trailing} -> {:error, :non_canonical}
      {:ok, _other_bytes} -> {:error, :non_canonical}
      {:error, _} = error -> error
    end
  end

  defp reencode(term) do
    case encode(term) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _reason} -> {:error, :non_canonical}
    end
  end

  defp normalize(%CBOR.Tag{tag: :bytes, value: bin}) when is_binary(bin),
    do: {:ok, {:bytes, bin}}

  defp normalize(%CBOR.Tag{}), do: {:error, :forbidden_type}
  defp normalize(f) when is_float(f), do: {:error, :float_forbidden}

  defp normalize(v) when is_integer(v) or is_binary(v) or is_boolean(v) or is_nil(v),
    do: {:ok, v}

  defp normalize(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case normalize(item) do
        {:ok, term} -> {:cont, {:ok, [term | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp normalize(map) when is_map(map) and not is_struct(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with true <- is_binary(key) or {:error, :bad_map_key},
           {:ok, term} <- normalize(value) do
        {:cont, {:ok, Map.put(acc, key, term)}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp normalize(_other), do: {:error, :forbidden_type}

  defp nif_encode(_term), do: :erlang.nif_error(:nif_not_loaded)
  defp nif_hash(_term), do: :erlang.nif_error(:nif_not_loaded)
end
