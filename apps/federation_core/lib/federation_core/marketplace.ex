defmodule FederationCore.Marketplace do
  @moduledoc """
  A *pure* public-marketplace ActivityPub profile and metadata wire contract.

  This code neither verifies HTTP signatures nor performs network requests.
  A host MUST verify the remote actor, enforce SSRF-safe network policy,
  persist a replay-deduplicated inbox/outbox, and never infer local business
  authority from a received activity. Public listings are advertisements,
  not order acceptance, inventory reservations or payment commitments.
  """

  @context "https://www.w3.org/ns/activitystreams"
  @public "https://www.w3.org/ns/activitystreams#Public"
  @schema "bizkit.marketplace.listing.v1"
  @max_amount 9_007_199_254_740_991
  @metadata_keys ~w(schema id seller revision name summary category price)
  @activity_keys ~w(@context id type actor to object)
  @object_keys ~w(type id attributedTo name summary url to attachment)

  @doc "Build a versioned, public listing snapshot, not an executable offer."
  def metadata(%{
        seller_actor: seller,
        listing_id: id,
        revision: revision,
        title: title,
        summary: summary,
        category: category,
        price: price
      }) do
    with :ok <- public_uri(seller),
         :ok <- public_uri(id),
         :ok <- same_origin(seller, id),
         true <- is_integer(revision) and revision >= 0 and revision <= @max_amount,
         :ok <- text(title, 160),
         :ok <- text(summary, 2048),
         :ok <- text(category, 64),
         {:ok, wire_price} <- encode_price(price) do
      {:ok,
       %{
         "schema" => @schema,
         "id" => id,
         "seller" => seller,
         "revision" => revision,
         "name" => title,
         "summary" => summary,
         "category" => category,
         "price" => wire_price
       }}
    else
      _ -> {:error, :invalid_marketplace_metadata}
    end
  end

  def metadata(_), do: {:error, :invalid_marketplace_metadata}

  @doc """
  Parse an exact-shape listing document after fetching it from the owning origin.

  The result is still a remote assertion: price, reputation, availability and
  other terms are not independently verified, and cannot admit a transaction.
  """
  def validate_metadata(%{} = value, verified_seller) do
    with true <- Enum.sort(Map.keys(value)) == Enum.sort(@metadata_keys),
         true <- value["schema"] == @schema,
         true <- value["seller"] == verified_seller,
         :ok <- public_uri(verified_seller),
         :ok <- public_uri(value["id"]),
         :ok <- same_origin(verified_seller, value["id"]),
         true <-
           is_integer(value["revision"]) and value["revision"] >= 0 and
             value["revision"] <= @max_amount,
         :ok <- text(value["name"], 160),
         :ok <- text(value["summary"], 2048),
         :ok <- text(value["category"], 64),
         :ok <- validate_price(value["price"]) do
      {:ok, value}
    else
      _ -> {:error, :invalid_marketplace_metadata}
    end
  end

  def validate_metadata(_, _), do: {:error, :invalid_marketplace_metadata}

  @doc """
  Encode a public Create/Update activity. The host must assign a unique
  activity ID and distribute it using a durable, authenticated AP outbox.
  """
  def publish(kind, %{"seller" => actor, "id" => listing_id} = listing, activity_id, metadata_url)
      when kind in [:create, :update] do
    with {:ok, _} <- validate_metadata(listing, actor),
         :ok <- public_uri(activity_id),
         :ok <- public_uri(metadata_url),
         :ok <- same_origin(actor, activity_id),
         :ok <- same_origin(actor, metadata_url) do
      object = %{
        "type" => "Page",
        "id" => listing_id,
        "attributedTo" => actor,
        "name" => listing["name"],
        "summary" => listing["summary"],
        "url" => listing_id,
        "to" => [@public],
        "attachment" => [
          %{"type" => "Link", "href" => metadata_url, "mediaType" => "application/json"}
        ]
      }

      {:ok,
       %{
         "@context" => @context,
         "id" => activity_id,
         "type" => if(kind == :create, do: "Create", else: "Update"),
         "actor" => actor,
         "to" => [@public],
         "object" => object
       }}
    else
      _ -> {:error, :invalid_marketplace_activity}
    end
  end

  def publish(_, _, _, _), do: {:error, :invalid_marketplace_activity}

  @doc "Encode a public listing withdrawal with a Tombstone, not a sale cancellation."
  def withdraw(actor, listing_id, activity_id) do
    with :ok <- public_uri(actor),
         :ok <- public_uri(listing_id),
         :ok <- public_uri(activity_id),
         :ok <- same_origin(actor, listing_id),
         :ok <- same_origin(actor, activity_id) do
      {:ok,
       %{
         "@context" => @context,
         "id" => activity_id,
         "type" => "Delete",
         "actor" => actor,
         "to" => [@public],
         "object" => %{"id" => listing_id, "type" => "Tombstone"}
       }}
    else
      _ -> {:error, :invalid_marketplace_activity}
    end
  end

  @doc """
  Decode ONLY after transport verified the activity's signing actor.

  The context is supplied by the authenticated host, never by the payload.
  Returned values are quarantine candidates; persistence must check freshness,
  author ownership, revisions, duplicate IDs, policy and moderation separately.
  """
  def decode_verified(%{} = activity, %{verified_actor: actor}) do
    with true <- Enum.sort(Map.keys(activity)) == Enum.sort(@activity_keys),
         true <- activity["@context"] == @context,
         true <- activity["actor"] == actor,
         true <- activity["to"] == [@public],
         :ok <- public_uri(actor),
         :ok <- public_uri(activity["id"]),
         :ok <- same_origin(actor, activity["id"]) do
      decode_object(activity["type"], actor, activity["object"], activity["id"])
    else
      _ -> {:error, :invalid_marketplace_activity}
    end
  end

  def decode_verified(_, _), do: {:error, :invalid_marketplace_activity}

  defp decode_object(kind, actor, %{} = object, activity_id)
       when kind in ["Create", "Update"] do
    with true <- Enum.sort(Map.keys(object)) == Enum.sort(@object_keys),
         true <- object["type"] == "Page",
         true <- object["attributedTo"] == actor,
         true <- object["url"] == object["id"],
         true <- object["to"] == [@public],
         :ok <- public_uri(object["id"]),
         :ok <- same_origin(actor, object["id"]),
         :ok <- text(object["name"], 160),
         :ok <- text(object["summary"], 2048),
         [%{"type" => "Link", "href" => terms_url, "mediaType" => "application/json"}] <-
           object["attachment"],
         :ok <- public_uri(terms_url),
         :ok <- same_origin(actor, terms_url) do
      {:ok,
       %{
         kind: if(kind == "Create", do: :create, else: :update),
         actor: actor,
         activity_id: activity_id,
         listing_id: object["id"],
         metadata_url: terms_url
       }}
    else
      _ -> {:error, :invalid_marketplace_activity}
    end
  end

  defp decode_object("Delete", actor, %{"id" => id, "type" => "Tombstone"} = object, activity_id) do
    with true <- map_size(object) == 2,
         :ok <- public_uri(id),
         :ok <- same_origin(actor, id) do
      {:ok, %{kind: :delete, actor: actor, activity_id: activity_id, listing_id: id}}
    else
      _ -> {:error, :invalid_marketplace_activity}
    end
  end

  defp decode_object(_, _, _, _), do: {:error, :invalid_marketplace_activity}

  defp encode_price(:quote), do: {:ok, %{"mode" => "quote"}}

  defp encode_price(%{minor_units: amount, currency: currency}) do
    value = %{"mode" => "fixed", "minor_units" => amount, "currency" => currency}
    if validate_price(value) == :ok, do: {:ok, value}, else: {:error, :invalid_price}
  end

  defp encode_price(_), do: {:error, :invalid_price}
  defp validate_price(%{"mode" => "quote"} = value) when map_size(value) == 1, do: :ok

  defp validate_price(
         %{"mode" => "fixed", "minor_units" => amount, "currency" => currency} = value
       )
       when map_size(value) == 3 and is_integer(amount) and amount >= 0 and
              amount <= @max_amount and is_binary(currency) do
    if String.match?(currency, ~r/\A[A-Z]{3}\z/), do: :ok, else: {:error, :invalid_price}
  end

  defp validate_price(_), do: {:error, :invalid_price}

  defp text(value, max) when is_binary(value) do
    if byte_size(value) in 1..max and String.valid?(value) and String.trim(value) != "",
      do: :ok,
      else: {:error, :invalid_text}
  end

  defp text(_, _), do: {:error, :invalid_text}

  # URL shape only; the HTTP host additionally needs DNS/IP/redirect SSRF checks.
  defp public_uri(value) when is_binary(value) and byte_size(value) <= 2048 do
    case URI.parse(value) do
      %URI{
        scheme: "https",
        host: host,
        userinfo: nil,
        fragment: nil,
        query: nil,
        path: path,
        port: port
      }
      when is_binary(host) and is_binary(path) and path != "" and port in [nil, 443] ->
        hostname = String.downcase(host)

        if Regex.match?(~r/\A[a-z0-9.-]+\z/, hostname) and
             String.contains?(hostname, ".") and not String.contains?(hostname, "..") and
             not String.ends_with?(hostname, ".local") and
             not String.ends_with?(hostname, ".internal") and
             match?({:error, _}, :inet.parse_address(String.to_charlist(hostname))),
           do: :ok,
           else: {:error, :unsafe_url}

      _ ->
        {:error, :unsafe_url}
    end
  end

  defp public_uri(_), do: {:error, :unsafe_url}

  defp same_origin(a, b) do
    if String.downcase(URI.parse(a).host) == String.downcase(URI.parse(b).host),
      do: :ok,
      else: {:error, :cross_origin_reference}
  end
end
