defmodule FederationService.Signature do
  @moduledoc "Narrow RSA-SHA256 HTTP Signature profile; authenticates requests, never business authority."
  alias FederationService.Network
  @signed "(request-target) host date digest content-type"
  @context "https://www.w3.org/ns/activitystreams"

  def public_key(private) do
    {:RSAPrivateKey, _, modulus, exponent, _, _, _, _, _, _, _} = private
    {:RSAPublicKey, modulus, exponent}
  end

  def pem(key), do: :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPublicKey, key)])

  def private!(path) do
    [entry] = :public_key.pem_decode(File.read!(path))
    key = :public_key.pem_entry_decode(entry)
    :ok = validate_key(public_key(key))
    key
  end

  def validate_key({:RSAPublicKey, n, 65537}) when is_integer(n) and n > 0 do
    if n >= Integer.pow(2, 2047) and n < Integer.pow(2, 4096),
      do: :ok,
      else: {:error, :invalid_key}
  end

  def validate_key(_), do: {:error, :invalid_key}

  def actor(actor, key, handle \\ nil) do
    document = %{
      "@context" => @context,
      "id" => actor,
      "type" => "Service",
      "inbox" => actor <> "/inbox",
      "outbox" => actor <> "/outbox",
      "publicKey" => %{
        "id" => actor <> "#main-key",
        "owner" => actor,
        "publicKeyPem" => pem(public_key(key))
      }
    }

    if handle == nil, do: document, else: Map.put(document, "preferredUsername", handle)
  end

  def discover(actor, opts \\ []) do
    with {:ok, doc} <- Network.json(actor, opts),
         true <- doc["id"] == actor and doc["type"] == "Service" and doc["@context"] == @context,
         true <- is_map(doc["publicKey"]) and map_size(doc["publicKey"]) == 3,
         %{"id" => id, "owner" => ^actor, "publicKeyPem" => pem} <- doc["publicKey"],
         true <- id == actor <> "#main-key" and is_binary(pem) and byte_size(pem) <= 8192,
         :ok <- Network.same_origin(actor, doc["inbox"]),
         :ok <- Network.same_origin(actor, doc["outbox"]),
         [entry] <- :public_key.pem_decode(pem),
         key <- :public_key.pem_entry_decode(entry),
         :ok <- validate_key(key) do
      {:ok, %{actor: actor, key_id: id, key: key, inbox: doc["inbox"], outbox: doc["outbox"]}}
    else
      _ -> {:error, :invalid_actor}
    end
  rescue
    _ -> {:error, :invalid_actor}
  end

  def sign(url, actor, private, body, now \\ DateTime.utc_now()) do
    {:ok, u} = Network.uri(url)

    headers = [
      {"host", u.host},
      {"date", date(now)},
      {"digest", digest(body)},
      {"content-type", "application/activity+json"}
    ]

    bytes = canonical(u.path, Map.new(headers))
    sig = :public_key.sign(bytes, :sha256, private) |> Base.encode64()

    headers ++
      [
        {"signature",
         "keyId=\"#{actor}#main-key\",algorithm=\"rsa-sha256\",headers=\"#{@signed}\",signature=\"#{sig}\""}
      ]
  end

  def verify(path, host, headers, body, identity, now \\ DateTime.utc_now()) do
    with true <- length(headers) <= 40,
         true <-
           Enum.all?(headers, fn {k, v} ->
             is_binary(k) and is_binary(v) and byte_size(v) <= 8192
           end),
         grouped <- Enum.group_by(headers, &elem(&1, 0), &elem(&1, 1)),
         true <-
           Enum.all?(
             ~w(host date digest content-type signature),
             &(length(Map.get(grouped, &1, [])) == 1)
           ),
         h <- Map.new(headers),
         true <- h["host"] == host,
         true <- h["content-type"] == "application/activity+json",
         true <- h["digest"] == digest(body),
         true <- fresh?(h["date"], now),
         [_, kid, sig64] <-
           Regex.run(
             ~r/\AkeyId="([^"\r\n]{1,2048})",algorithm="rsa-sha256",headers="\(request-target\) host date digest content-type",signature="([A-Za-z0-9+\/=]{1,1024})"\z/,
             h["signature"]
           ),
         true <- kid == identity.key_id,
         {:ok, sig} <- Base.decode64(sig64),
         true <- :public_key.verify(canonical(path, h), :sha256, sig, identity.key) do
      :ok
    else
      _ -> {:error, :invalid_signature}
    end
  rescue
    _ -> {:error, :invalid_signature}
  end

  defp canonical(path, h),
    do:
      "(request-target): post #{path}\nhost: #{h["host"]}\ndate: #{h["date"]}\ndigest: #{h["digest"]}\ncontent-type: #{h["content-type"]}"

  defp digest(body), do: "SHA-256=" <> Base.encode64(:crypto.hash(:sha256, body))
  defp date(now), do: Calendar.strftime(now, "%a, %d %b %Y %H:%M:%S GMT")

  defp fresh?(value, now) do
    months = ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

    with [_, weekday, day, month, year, hour, minute, second] <-
           Regex.run(
             ~r/\A(Mon|Tue|Wed|Thu|Fri|Sat|Sun), (\d{2}) ([A-Z][a-z]{2}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT\z/,
             value
           ),
         m when is_integer(m) <- Enum.find_index(months, &(&1 == month)),
         {:ok, d} <- Date.new(String.to_integer(year), m + 1, String.to_integer(day)),
         {:ok, t} <-
           Time.new(String.to_integer(hour), String.to_integer(minute), String.to_integer(second)),
         {:ok, dt} <- DateTime.new(d, t, "Etc/UTC"),
         true <- Calendar.strftime(dt, "%a") == weekday do
      abs(DateTime.diff(now, dt)) <= 300
    else
      _ -> false
    end
  end
end
