defmodule Dispatch.RestaurantDelivery do
  @moduledoc """
  Operator-side source attestation for an arranged restaurant delivery.
  This is a trusted release command, not a public Dispatch endpoint. The
  operator reviews physical evidence before attesting. This command checks
  Dispatch's own tenant, load, stop and document records before signing.
  It never copies an address, document locator or money claim to the ledger.
  """

  alias CoopSubstrate.{Canonical, Crypto}
  alias CoopSubstrate.Protocol.Envelope

  @ops ~w(accept picked_up delivered)
  @base_keys ~w(op order_id load_id assignment_id command_id expected_version)
  @source_query """
  SELECT a.status, s.kind, p.category
    FROM loads l
    JOIN assignments a ON a.id = $5 AND a.load_id = l.id AND a.tenant_id = l.tenant_id
    LEFT JOIN document_references p ON p.id = $4::uuid AND p.tenant_id = l.tenant_id
    LEFT JOIN stops s ON s.id = p.stop_id AND s.load_id = l.id AND s.tenant_id = l.tenant_id
   WHERE l.id = $1 AND l.tenant_id = $2 AND l.external_reference = $3
  """

  @doc "The exact Dispatch external reference for one restaurant order."
  def load_reference(chapter, merchant, order),
    do: "restaurant:" <> Enum.join([chapter, merchant, order], ":")

  @doc "Verify the Dispatch source and submit a signed handoff to the restaurant host."
  def publish(input) do
    with :ok <- validate(input),
         {:ok, config} <- configuration(),
         :ok <- confirm_source(input, config),
         {:ok, body} <- signed_body(input, config) do
      case Finch.request(
             Finch.build(:post, config.url, [{"content-type", "application/json"}], body),
             Dispatch.Finch
           ) do
        {:ok, %{status: code, body: response}} when code in [200, 201] ->
          Jason.decode(response)

        {:ok, %{status: code, body: response}} ->
          {:error, {:restaurant_refused, code, response}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp validate(%{"op" => op, "expected_version" => version} = p)
       when op in @ops and is_integer(version) and version >= 0 do
    fields = if op == "accept", do: @base_keys, else: ["reviewed", "proof_id" | @base_keys]

    with true <- Enum.sort(Map.keys(p)) == Enum.sort(fields),
         true <- Enum.all?([p["order_id"], p["command_id"]], &token?/1),
         true <- op == "accept" or p["reviewed"] == true do
      :ok
    else
      _ -> {:error, :invalid_dispatch_command}
    end
  end

  defp validate(_), do: {:error, :invalid_dispatch_command}

  @doc false
  def confirm_source(input, config) do
    reference = load_reference(config.chapter, config.merchant, input["order_id"])

    with {:ok, load} <- Ecto.UUID.dump(input["load_id"]),
         {:ok, tenant} <- Ecto.UUID.dump(config.tenant),
         {:ok, proof} <- proof_id(input),
         {:ok, assignment} <- Ecto.UUID.dump(input["assignment_id"]),
         {:ok, %{rows: [row]}} <-
           Ecto.Adapters.SQL.query(Dispatch.Repo, @source_query, [
             load,
             tenant,
             reference,
             proof,
             assignment
           ]),
         true <- source_matches?(input["op"], row) do
      :ok
    else
      _ -> {:error, :dispatch_source_not_confirmed}
    end
  end

  defp proof_id(%{"op" => "accept"}), do: {:ok, nil}
  defp proof_id(%{"proof_id" => id}), do: Ecto.UUID.dump(id)

  @doc false
  def source_matches?("accept", ["ACTIVE", nil, nil]), do: true

  def source_matches?("picked_up", [status, "PICKUP", "PICKUP_DOCUMENT"]),
    do: status in ["ACTIVE", "COMPLETED"]

  def source_matches?("delivered", ["COMPLETED", "DELIVERY", "PROOF_OF_DELIVERY"]), do: true
  def source_matches?(_, _), do: false

  defp signed_body(input, config) do
    payload =
      input
      |> Map.delete("reviewed")
      |> Map.merge(%{"merchant_id" => config.merchant, "tenant_id" => config.tenant})

    signer = %{
      role: "restaurant_dispatch",
      key_id: config.key_id,
      pubkey: Crypto.pubkey_from_seed(config.seed)
    }

    with {:ok, env} <-
           Envelope.new(%{
             chapter_id: config.chapter,
             type: "RestaurantDeliveryStepV1",
             payload: payload,
             signers: [signer],
             timestamp_ms: System.system_time(:millisecond)
           }),
         {:ok, signed} <- Envelope.sign(env, signer.key_id, config.seed),
         {:ok, record} <- Canonical.encode(Envelope.full_record_term(signed)) do
      Jason.encode(%{"record" => Base.url_encode64(record, padding: false)})
    end
  end

  defp configuration do
    chapter = System.get_env("RESTAURANT_DISPATCH_CHAPTER")
    merchant = System.get_env("RESTAURANT_DISPATCH_MERCHANT")
    tenant = System.get_env("RESTAURANT_DISPATCH_TENANT")
    key_id = System.get_env("RESTAURANT_DISPATCH_KEY_ID")
    base = System.get_env("RESTAURANT_DISPATCH_URL")
    seed_path = System.get_env("RESTAURANT_DISPATCH_SEED_FILE")

    with true <- Enum.all?([chapter, merchant, key_id], &token?/1),
         {:ok, _} <- Ecto.UUID.dump(tenant),
         {:ok, url} <- endpoint(base),
         true <- is_binary(seed_path),
         {:ok, encoded} <- File.read(seed_path),
         {:ok, <<_::256>> = seed} <- Base.decode64(String.trim(encoded)) do
      {:ok,
       %{
         chapter: chapter,
         merchant: merchant,
         tenant: tenant,
         key_id: key_id,
         seed: seed,
         url: url
       }}
    else
      _ -> {:error, :invalid_dispatch_delivery_configuration}
    end
  end

  defp token?(value),
    do:
      is_binary(value) and byte_size(value) in 1..128 and
        Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, value)

  defp endpoint(base) when is_binary(base) do
    with {:ok,
          %URI{scheme: scheme, host: host, path: path, query: nil, fragment: nil, userinfo: nil}} <-
           URI.new(base),
         true <- is_binary(host) and host != "" and path in [nil, "", "/"],
         true <-
           scheme == "https" or (scheme == "http" and host in ["127.0.0.1", "localhost", "::1"]) do
      {:ok, String.trim_trailing(base, "/") <> "/api/restaurant-delivery"}
    else
      _ -> {:error, :invalid_restaurant_url}
    end
  end

  defp endpoint(_), do: {:error, :invalid_restaurant_url}
end
