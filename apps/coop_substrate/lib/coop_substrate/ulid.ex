defmodule CoopSubstrate.ULID do
  @moduledoc """
  ULID generation (https://github.com/ulid/spec): 48-bit millisecond
  timestamp + 80 bits of randomness, Crockford base32, 26 characters.

  Used for `event_id`. The embedded timestamp is a convenience for humans
  and generators only — ordering authority is sequence, never wall-clock
  (SUBSTRATE.md §1.2), so ULID monotonicity is NOT relied upon anywhere.
  """

  import Bitwise

  @crockford ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"

  @spec generate(non_neg_integer()) :: String.t()
  def generate(timestamp_ms \\ System.system_time(:millisecond))
      when is_integer(timestamp_ms) and timestamp_ms >= 0 and timestamp_ms < 1 <<< 48 do
    <<rand::80>> = :crypto.strong_rand_bytes(10)
    encode(timestamp_ms * (1 <<< 80) + rand, 26, [])
  end

  @spec valid?(term()) :: boolean()
  def valid?(<<first, _rest::binary-size(25)>> = ulid) when is_binary(ulid) do
    # 26 chars * 5 bits = 130 bits for a 128-bit value: first char <= "7".
    first <= ?7 and ulid |> String.to_charlist() |> Enum.all?(&(&1 in @crockford))
  end

  def valid?(_), do: false

  @doc """
  The ULID's 128 bits in UUID string form. The event store keys events by
  uuid; deriving it from the ULID makes appending the same event twice a
  database-level conflict instead of a silent duplicate.
  """
  @spec to_uuid(String.t()) :: {:ok, String.t()} | {:error, :bad_ulid}
  def to_uuid(ulid) do
    if valid?(ulid) do
      n =
        ulid
        |> String.to_charlist()
        |> Enum.reduce(0, fn char, acc -> acc * 32 + Enum.find_index(@crockford, &(&1 == char)) end)

      <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
        e::binary-size(12)>> = Base.encode16(<<n::128>>, case: :lower)

      {:ok, "#{a}-#{b}-#{c}-#{d}-#{e}"}
    else
      {:error, :bad_ulid}
    end
  end

  defp encode(_n, 0, acc), do: List.to_string(acc)

  defp encode(n, chars_left, acc) do
    encode(div(n, 32), chars_left - 1, [Enum.at(@crockford, rem(n, 32)) | acc])
  end
end
