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

  defp nif_encode(_term), do: :erlang.nif_error(:nif_not_loaded)
  defp nif_hash(_term), do: :erlang.nif_error(:nif_not_loaded)
end
