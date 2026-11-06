defmodule CommerceCore.MerchantPilot.InvalidEvidence do
  defexception [:reason, message: "Invalid merchant pilot evidence"]
end

defmodule CommerceCore.MerchantPilot.Validation do
  @moduledoc false
  alias CommerceCore.MerchantPilot.InvalidEvidence
  @roles ~w(merchant servicing_store platform)
  def roles, do: @roles

  def check!(condition, reason) do
    if condition != true, do: raise(InvalidEvidence, reason: reason)
    :ok
  end

  def fields!(row, names) do
    check!(is_map(row) and Enum.sort(Map.keys(row)) == Enum.sort(String.split(names)), :fields)
    row
  end

  def rows!(value) do
    check!(is_list(value), :array)
    value
  end

  def token!(value) do
    check!(is_binary(value) and Regex.match?(~r/\A[0-9a-f]{32}\z/, value), :token)
    value
  end

  def currency!(value) do
    check!(is_binary(value) and Regex.match?(~r/\A[A-Z]{3}\z/, value), :currency)
    value
  end

  def amount!(value, nullable \\ false) do
    check!((nullable and is_nil(value)) or (is_integer(value) and value >= 0), :amount)
    value
  end

  def positive!(value) do
    check!(is_integer(value) and value > 0, :positive_integer)
    value
  end

  def flag!(value) do
    check!(is_boolean(value), :boolean)
    value
  end

  def time!(value) do
    check!(
      is_binary(value) and
        Regex.match?(~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/, value),
      :timestamp
    )

    case DateTime.from_iso8601(value) do
      {:ok, instant, 0} -> DateTime.to_unix(instant)
      _ -> raise InvalidEvidence, reason: :timestamp
    end
  end

  def occurred!(value, earliest, cutoff, optional \\ false) do
    if optional and is_nil(value) do
      nil
    else
      instant = time!(value)
      check!(earliest <= instant and instant <= cutoff, :observation_interval)
      instant
    end
  end

  def utc(value), do: value |> DateTime.from_unix!() |> DateTime.to_iso8601()

  def unique!(map, key, value) do
    check!(not Map.has_key?(map, key), :duplicate)
    Map.put(map, key, value)
  end

  def ref!(map, key) do
    token!(key)
    check!(Map.has_key?(map, key), :reference)
    Map.fetch!(map, key)
  end

  def evidence!(values) do
    rows!(values)
    check!(values != [], :evidence)
    Enum.each(values, &token!/1)
    check!(length(values) == length(Enum.uniq(values)), :duplicate_evidence)
  end

  def protect(fun) do
    {:ok, fun.()}
  rescue
    _ in [
      InvalidEvidence,
      ArgumentError,
      KeyError,
      BadMapError,
      FunctionClauseError,
      ArithmeticError
    ] ->
      {:error, :invalid_evidence}
  end
end
