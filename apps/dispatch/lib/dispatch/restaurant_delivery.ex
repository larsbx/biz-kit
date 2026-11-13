defmodule Dispatch.RestaurantDelivery do
  @moduledoc """
  Operator-side source attestation for an arranged restaurant delivery.
  This is a trusted release command, not a public Dispatch endpoint. The
  operator reviews physical evidence before attesting. This command checks
  Dispatch's own tenant, load, stop and document records before signing.
  It never copies an address, document locator or money claim to the ledger.
  """

  alias CoopSubstrate.{Canonical, Crypto, RestaurantDeliveryWork}
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
  def load_reference(chapter, merchant, order, source \\ :restaurant),
    do: Enum.join([Atom.to_string(source), chapter, merchant, order], ":")

  @doc "Verify the Dispatch source and submit a signed handoff to the restaurant host."
  def publish(input) do
    with :ok <- validate(input),
         {:ok, config} <- configuration(),
         :ok <- confirm_source(input, config),
         {:ok, body} <- signed_body(input, config) do
      post(config.url, body)
    end
  end

  @doc false
  def work(config, cursor),
    do:
      post(
        config.url <> "/work",
        Jason.encode!(RestaurantDeliveryWork.sign(config, cursor, config.seed))
      )

  @doc false
  def publish_automated(input, config) do
    with {:ok, body} <- signed_body(Map.put(input, "automated", true), config) do
      post(config.url, body)
    end
  end

  defp post(url, body) do
    case Finch.request(
           Finch.build(:post, url, [{"content-type", "application/json"}], body),
           Dispatch.Finch,
           receive_timeout: 5_000
         ) do
      {:ok, %{status: code, body: response}} when code in [200, 201] ->
        Jason.decode(response)

      {:ok, %{status: code, body: response}} ->
        {:error, {:restaurant_refused, code, response}}

      {:error, reason} ->
        {:error, reason}
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
    {type, role, scope_field} =
      case Map.get(config, :source, :restaurant) do
        :restaurant -> {"RestaurantDeliveryStepV1", "restaurant_dispatch", "merchant_id"}
        :procurement -> {"ProcurementDispatchStepV1", "procurement_dispatch", "cooperative_id"}
      end

    payload =
      input
      |> Map.delete("reviewed")
      |> Map.merge(%{scope_field => config.merchant, "tenant_id" => config.tenant})

    signer = %{
      role: role,
      key_id: config.key_id,
      pubkey: Crypto.pubkey_from_seed(config.seed)
    }

    with {:ok, env} <-
           Envelope.new(%{
             chapter_id: config.chapter,
             type: type,
             payload: payload,
             signers: [signer],
             timestamp_ms: System.system_time(:millisecond)
           }),
         {:ok, signed} <- Envelope.sign(env, signer.key_id, config.seed),
         {:ok, record} <- Canonical.encode(Envelope.full_record_term(signed)) do
      Jason.encode(%{"record" => Base.url_encode64(record, padding: false)})
    end
  end

  @doc false
  def configuration(source \\ :restaurant) do
    chapter = env(source, "CHAPTER")
    merchant = env(source, if(source == :procurement, do: "COOPERATIVE", else: "MERCHANT"))
    tenant = env(source, "TENANT")
    key_id = env(source, "KEY_ID")
    base = env(source, "URL")
    seed_path = env(source, "SEED_FILE")

    with true <- Enum.all?([chapter, merchant, key_id], &token?/1),
         {:ok, _} <- Ecto.UUID.dump(tenant),
         {:ok, base} <- endpoint(base),
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
         source: source,
         url:
           base <>
             if(source == :procurement,
               do: "/api/procurement-dispatch",
               else: "/api/restaurant-delivery"
             )
       }}
    else
      _ -> {:error, :invalid_dispatch_delivery_configuration}
    end
  end

  @doc false
  def env(source, field) when source in [:restaurant, :procurement],
    do: System.get_env(String.upcase(Atom.to_string(source)) <> "_DISPATCH_" <> field)

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
      {:ok, String.trim_trailing(base, "/")}
    else
      _ -> {:error, :invalid_restaurant_url}
    end
  end

  defp endpoint(_), do: {:error, :invalid_restaurant_url}
end
