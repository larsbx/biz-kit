defmodule ResearchExchange.Evidence do
  @moduledoc """
  Domain-separated canonical receipts. This is a specified JSON subset, not JCS:
  UTF-8 string keys sorted by bytes; integers only; no floats or atom keys.
  Digests identify bytes. MACs authenticate the local server, not public provenance.
  """
  def canonical(map) when is_map(map) do
    entries =
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} ->
        true = is_binary(k)
        [canonical(k), ":", canonical(v)]
      end)

    IO.iodata_to_binary(["{", Enum.intersperse(entries, ","), "}"])
  end

  def canonical(xs) when is_list(xs),
    do: IO.iodata_to_binary(["[", Enum.intersperse(Enum.map(xs, &canonical/1), ","), "]"])

  # OTP's JSON encoder treats Elixir nil as an ordinary atom (the string
  # "nil"). Normalize JSON null explicitly rather than authenticating that text.
  def canonical(nil), do: "null"

  def canonical(x) when is_binary(x) or is_integer(x) or is_boolean(x),
    do: IO.iodata_to_binary(:json.encode(x))

  def hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  def digest(domain, value), do: hash(domain <> "\n" <> canonical(value))

  def mac(key, domain, value),
    do:
      :crypto.mac(:hmac, :sha256, key, domain <> "\n" <> canonical(value))
      |> Base.encode16(case: :lower)

  def equal?(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b),
    do: :crypto.hash_equals(a, b)

  def equal?(_, _), do: false

  def receipt(payload, key) do
    %{
      "payload" => payload,
      "sha256" => digest("research-exchange/receipt/v1", payload),
      "server_mac" => mac(key, "research-exchange/receipt/v1", payload)
    }
  end

  def verify_receipt?(%{"payload" => p, "sha256" => h, "server_mac" => m}, key),
    do:
      equal?(h, digest("research-exchange/receipt/v1", p)) and
        equal?(m, mac(key, "research-exchange/receipt/v1", p))

  def verify_receipt?(_, _), do: false
end
