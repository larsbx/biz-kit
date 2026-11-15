defmodule RestaurantHost.Management do
  @moduledoc """
  Operator commands for the restaurant release. The host holds the exact
  command for a declared governance key, and its own Log admits the signature.
  The operator's release copy signs locally without starting a ledger writer.
  """

  alias CoopSubstrate.Commands
  alias CoopSubstrate.Governance.Client
  alias CoopSubstrate.Harness.Ops
  alias RestaurantCore.{Delivery, Menu}
  alias RestaurantHost.{DeviceGrants, Restaurant}

  @operations %{
    "publish-menu" => "RestaurantMenuPublishedV1",
    "grant-dispatch" => "RestaurantDispatchGrantedV1",
    "revoke-device" => "RestaurantDeviceRevokedV1"
  }

  def prepare(%Restaurant{} = r, operation, payload, key_id) do
    with {:ok, type} <- Map.fetch(@operations, operation),
         true <- payload["merchant_id"] == r.merchant,
         {:ok, normalized} <- normalize(operation, payload),
         true <- operation != "publish-menu" or payload["currency"] == Atom.to_string(r.currency),
         {:ok, signer} <- Commands.governance_signer(r.chapter, key_id) do
      Commands.hold(owner(r, operation), r.chapter, type, normalized, signer)
    else
      {:error, _} = error -> error
      _ -> {:error, :bad_request}
    end
  end

  def submit(%Restaurant{} = r, operation, id, <<_::512>> = signature) do
    if Map.has_key?(@operations, operation) and is_binary(id) and byte_size(id) in 1..128,
      do: Commands.submit(owner(r, operation), id, signature),
      else: {:error, :bad_request}
  end

  defp owner(r, operation), do: {:restaurant_management, r.chapter, r.merchant, operation}

  defp valid?("publish-menu", %{"expected_revision" => revision} = payload) do
    map_size(payload) == 4 and is_integer(revision) and revision >= 0 and
      Menu.valid?(payload["currency"], payload["items"])
  end

  defp valid?("revoke-device", %{"key_id" => key} = payload),
    do: map_size(payload) == 2 and DeviceGrants.identifier?(key)

  defp valid?(_, _), do: false

  defp normalize(
         "grant-dispatch",
         %{"key_id" => key, "tenant_id" => tenant, "pubkey" => encoded} = p
       )
       when map_size(p) == 4 and is_binary(encoded) do
    with true <- DeviceGrants.identifier?(key) and Delivery.uuid?(tenant),
         {:ok, <<_::256>> = pubkey} <- Base.url_decode64(encoded, padding: false) do
      {:ok, %{p | "pubkey" => {:bytes, pubkey}}}
    else
      _ -> {:error, :bad_request}
    end
  end

  defp normalize(operation, payload) do
    if valid?(operation, payload), do: {:ok, payload}, else: {:error, :bad_request}
  end

  @doc "Sign only the exact locally supplied chapter, event type and payload."
  def approve(base, chapter, operation, payload, signer) do
    with {:ok, type} <- Map.fetch(@operations, operation),
         {:ok, normalized} <- normalize(operation, payload) do
      Client.sign_held(
        base <> "/api/restaurant-management/" <> operation,
        signer,
        &matches?(&1, chapter, type, normalized),
        %{"chapter_id" => chapter, "payload" => payload}
      )
    else
      _ -> {:error, :bad_request}
    end
  end

  defp matches?(core, chapter, type, payload),
    do: core["chapter_id"] == chapter and core["type"] == type and core["payload"] == payload

  def main(args) do
    case run(args) do
      {:ok, %{"event_id" => id}} ->
        IO.puts("Admitted restaurant command #{id}")

      error ->
        IO.puts(:stderr, "Restaurant command refused: #{inspect(error, limit: 5)}")
        IO.puts(:stderr, "Usage: restaurant.manage OP FILE --chapter CHAPTER --server URL")
        System.halt(1)
    end
  end

  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [chapter: :string, server: :string])

    with [operation, path] <- positional,
         [] <- invalid,
         chapter = opts[:chapter],
         true <- DeviceGrants.identifier?(chapter),
         {:ok, base} <- server(opts[:server]),
         {:ok, input} <- File.read(path),
         {:ok, %{"merchant_id" => merchant} = payload} <- Jason.decode(input),
         true <- DeviceGrants.identifier?(merchant),
         {:ok, signer} <- Ops.load_signer("governance") do
      approve(base, chapter, operation, payload, signer)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_options}
    end
  end

  defp server(base) when is_binary(base) do
    case URI.new(base) do
      {:ok,
       %URI{host: host, scheme: scheme, path: path, userinfo: nil, query: nil, fragment: nil}}
      when is_binary(host) and host != "" and path in [nil, "", "/"] and
             (scheme == "https" or
                (scheme == "http" and host in ["localhost", "127.0.0.1", "::1"])) ->
        {:ok, String.trim_trailing(base, "/")}

      _ ->
        {:error, :invalid_server}
    end
  end

  defp server(_), do: {:error, :invalid_server}
end
