defmodule CoopSubstrate.Log.Serializer do
  @moduledoc """
  Pass-through serializer: event data/metadata are already
  `CoopEventCanonicalV1` bytes when they reach the store, and MUST be stored
  and returned verbatim — the signature and both hash-chains cover exactly
  these bytes. Any transformation here would be tampering.
  """

  @behaviour EventStore.Serializer

  @impl true
  def serialize(nil), do: nil
  def serialize(bytes) when is_binary(bytes), do: bytes

  @impl true
  def deserialize(bytes, _config), do: bytes
end
