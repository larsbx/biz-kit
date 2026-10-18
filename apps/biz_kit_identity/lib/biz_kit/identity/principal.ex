defmodule BizKit.Identity.Principal do
  @moduledoc """
  A principal ID: `prn_` and 128 random bits in lowercase base32. Minted by
  biz-kit, never derived from a provider's user ID, so it outlives any
  provider.
  """

  @type id :: String.t()

  @spec new_id() :: id()
  def new_id,
    do: "prn_" <> Base.encode32(:crypto.strong_rand_bytes(16), case: :lower, padding: false)

  @spec valid?(term()) :: boolean()
  def valid?(id), do: is_binary(id) and id =~ ~r/\Aprn_[a-z2-7]{26}\z/
end
