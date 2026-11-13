defmodule TaskHost.InfrastructureReview do
  @moduledoc """
  Builds a read-only handoff to Ship from operator-configured review metadata.
  Ship resolves the catalog binding and authorizes source access on arrival.
  """

  @integrity_status "integrity-only; receipt remains unsigned and unauthenticated"
  @keel_revision "3a5f16476e8f0f5ed3290fa5c61b1d7be1b0badd"
  @keel_manifest_digest "28137d15ecffb90c475033972891105db967f851bd59f53c1b00077986516b64"
  @keel_roles [
    {"Proof", "Machine-checked claims only"},
    {"Kernel", "Canonical executable validation only when designated"},
    {"Reference", "Pure executable semantics and vector generation"},
    {"Oracle", "Non-authoritative research and differential checking"},
    {"Adapter", "Generated or mechanically constrained translation"}
  ]

  @doc "Validate the closed Ship catalog record and browser destination."
  def valid?(%{"origin" => origin, "key" => key, "record" => record} = review)
      when map_size(review) == 3 do
    match?({:ok, _}, parse_origin(origin)) and
      matches?(key, ~r/\A[a-z][a-z0-9-]{0,63}\z/) and record?(record)
  end

  def valid?(_review), do: false

  @doc "Build the direct, evidence-bound Ship URL without making an upstream request."
  def ship_link(%{"origin" => origin, "key" => key, "record" => record} = review, biz_host) do
    with true <- valid?(review),
         {:ok, %{host: host}} <- parse_origin(origin),
         false <- host == String.downcase(String.trim_trailing(biz_host, ".")) do
      # Ship hashes Python's sorted compact JSON for [key, record]. Every
      # admitted string is ASCII and every object below uses sorted keys.
      json = :json.encode([key, record], &encode_sorted/2)
      evidence = sha256(json)
      {:ok, origin <> "/graft/" <> key <> "/source?evidence=" <> evidence}
    else
      _ -> {:error, :invalid_ship_review}
    end
  end

  @doc "Accept only the exact Keel manifest reviewed at the declared revision."
  def keel(path) when is_binary(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= 4096 <- File.stat(path),
         {:ok, bytes} when is_binary(bytes) <-
           File.open(path, [:read, :binary], &IO.binread(&1, 4097)),
         @keel_manifest_digest <- sha256(bytes) do
      {:ok, %{repository: "larsbx/keel", revision: @keel_revision, roles: @keel_roles}}
    else
      _ -> {:error, :keel_manifest_unavailable_or_incompatible}
    end
  end

  def keel(_path), do: {:error, :keel_manifest_unavailable_or_incompatible}

  defp parse_origin(origin) when is_binary(origin) and byte_size(origin) <= 270 do
    with true <- matches?(origin, ~r/\Ahttps?:\/\/[a-z0-9.-]+(?::[1-9][0-9]{0,4})?\z/),
         {:ok, %URI{scheme: scheme, host: host, port: port} = uri} <- URI.new(origin),
         true <- valid_host?(host),
         true <- port in 1..65_535,
         true <- scheme == "https" or host in ["localhost", "127.0.0.1"] do
      {:ok, uri}
    else
      _ -> {:error, :invalid_origin}
    end
  end

  defp parse_origin(_origin), do: {:error, :invalid_origin}

  defp valid_host?(host) do
    Enum.all?(String.split(host, "."), fn label ->
      matches?(label, ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/)
    end) and
      (host == "127.0.0.1" or Regex.match?(~r/\A[a-z]/, List.last(String.split(host, "."))))
  end

  defp record?(
         %{
           "repository" => "larsbx/biz-kit",
           "destination" => destination,
           "verifier" => verifier,
           "report" =>
             %{
               "commit" => commit,
               "tree" => tree,
               "bundle_sha256" => bundle,
               "status" => @integrity_status
             } = report
         } = record
       )
       when map_size(record) == 4 and map_size(report) == 4 do
    matches?(destination, ~r/\A[a-z][a-z0-9-]{0,63}\z/) and
      matches?(verifier, ~r/\A[0-9a-f]{40}\z/) and
      matches?(commit, ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/) and
      matches?(tree, ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/) and
      byte_size(commit) == byte_size(tree) and
      matches?(bundle, ~r/\A[0-9a-f]{64}\z/)
  end

  defp record?(_record), do: false

  defp encode_sorted(value, encode) when is_map(value),
    do: :json.encode_key_value_list(Enum.sort(value), encode)

  defp encode_sorted(value, encode), do: :json.encode_value(value, encode)

  defp matches?(value, pattern), do: is_binary(value) and Regex.match?(pattern, value)

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
