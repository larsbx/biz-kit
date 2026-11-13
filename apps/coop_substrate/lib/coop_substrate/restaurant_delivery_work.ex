defmodule CoopSubstrate.RestaurantDeliveryWork do
  @moduledoc false
  alias CoopSubstrate.{Canonical, Crypto}
  alias CoopSubstrate.Feed.{Access, Nonces}
  alias RestaurantCore.Admission

  def sign(scope, cursor, seed) do
    request = %{
      "chapter" => scope.chapter,
      "merchant" => scope.merchant,
      "tenant" => scope.tenant,
      "key_id" => scope.key_id,
      "cursor" => cursor,
      "nonce" => Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
      "timestamp_ms" => System.system_time(:millisecond)
    }

    Map.put(
      request,
      "signature",
      Base.url_encode64(Crypto.sign(bytes(request, Map.get(scope, :source, :restaurant)), seed),
        padding: false
      )
    )
  end

  def authorize(request, state, chapter, merchant) do
    authorize_scoped(request, chapter, merchant, :restaurant, fn tenant, key_id ->
      Admission.dispatch_key(state, chapter, merchant, tenant, key_id)
    end)
  end

  def authorize_scoped(
        %{
          "chapter" => chapter,
          "merchant" => merchant,
          "tenant" => tenant,
          "key_id" => key_id,
          "cursor" => cursor,
          "nonce" => nonce,
          "timestamp_ms" => timestamp,
          "signature" => sig
        } = request,
        chapter,
        merchant,
        source,
        key
      )
      when map_size(request) == 8 and is_binary(tenant) and is_binary(key_id) and
             is_binary(cursor) and byte_size(cursor) <= 128 and is_binary(nonce) and
             byte_size(nonce) in 16..128 and is_integer(timestamp) and is_binary(sig) do
    with true <- abs(System.system_time(:millisecond) - timestamp) <= Access.window_ms(),
         {:ok, <<_::512>> = signature} <- Base.url_decode64(sig, padding: false),
         {:ok, pubkey} <- key.(tenant, key_id),
         true <- Crypto.verify(bytes(Map.delete(request, "signature"), source), signature, pubkey),
         :ok <- Nonces.claim(nonce, timestamp) do
      {:ok, tenant, cursor}
    else
      _ -> {:error, :forbidden}
    end
  end

  def authorize_scoped(_, _, _, _, _), do: {:error, :forbidden}

  defp bytes(request, :restaurant),
    do: Canonical.encode!(Map.put(request, "domain", "RestaurantDeliveryWorkV1"))

  defp bytes(request, :procurement),
    do: Canonical.encode!(Map.put(request, "domain", "ProcurementDeliveryWorkV1"))
end
