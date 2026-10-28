defmodule MarketingCore.Touchpoint do
  @moduledoc """
  Opaque public marketing engagement codes adapted from Eatsbot's touchpoints.

  The host is responsible for merchant/campaign binding, unique insertion and
  revocation. These QR/NFC codes are **not** participant identity, proof of
  consent or Hawala transaction authorization.
  """

  @alphabet ~c"23456789ABCDEFGHJKMNPQRSTUVWXYZ"

  @spec code(pos_integer()) :: String.t()
  def code(size) when is_integer(size) and size in 1..64 do
    n = length(@alphabet)
    limit = 256 - rem(256, n)

    Stream.repeatedly(fn -> :crypto.strong_rand_bytes(size) end)
    |> Stream.flat_map(&:binary.bin_to_list/1)
    |> Stream.filter(&(&1 < limit))
    |> Enum.take(size)
    |> Enum.map(&Enum.at(@alphabet, rem(&1, n)))
    |> List.to_string()
  end
end
