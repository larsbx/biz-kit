defmodule CommerceCore.MerchantPilot.JSON do
  @moduledoc "Strict string-key JSON with duplicate-key rejection and canonical encoding. Requires OTP 27+."
  import CommerceCore.MerchantPilot.Validation

  def decode!(bytes) when is_binary(bytes) do
    check!(String.to_integer(System.otp_release()) >= 27, :otp_version)

    options = %{
      null: nil,
      object_start: fn _ -> %{} end,
      object_push: fn key, value, acc -> unique!(acc, key, value) end,
      object_finish: fn acc, old -> {acc, old} end
    }

    {value, _, rest} = :json.decode(bytes, :ok, options)
    check!(String.trim(rest) == "", :trailing_json)
    value
  end

  def encode!(value) do
    check!(String.to_integer(System.otp_release()) >= 27, :otp_version)
    IO.iodata_to_binary(:json.encode(value, &encode/2))
  end

  defp encode(nil, _), do: "null"

  defp encode(map, encoder) when is_map(map) do
    check!(Enum.all?(Map.keys(map), &is_binary/1), :json_keys)
    :json.encode_key_value_list(Enum.sort(map), encoder)
  end

  defp encode(value, encoder), do: :json.encode_value(value, encoder)
  def digest(value), do: :crypto.hash(:sha256, encode!(value)) |> Base.encode16(case: :lower)
end
