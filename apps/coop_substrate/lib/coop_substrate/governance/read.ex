defmodule CoopSubstrate.Governance.Read do
  @moduledoc """
  A read signed by a governance key (docs/architecture/2026-10-19-offboarding.md),
  for what only an administrator should see, such as everything a principal
  holds. Like a feed read (`Feed.Access`), the signature binds the method,
  path, time and nonce, and the nonce is spent once (`Feed.Nonces`).

  The result is the chapters whose declared governance keys include this
  key: the read shows those chapters only.
  """

  alias CoopSubstrate.{Canonical, Crypto, Log}
  alias CoopSubstrate.Feed.{Access, Nonces}

  @type request :: %{
          method: String.t(),
          path: String.t(),
          timestamp_ms: integer(),
          nonce: String.t(),
          key_id: String.t()
        }

  @spec signing_bytes(request()) :: binary()
  def signing_bytes(r),
    do:
      Canonical.encode!(%{
        "schema" => "CoopGovernanceReadV1",
        "method" => r.method,
        "path" => r.path,
        "timestamp_ms" => r.timestamp_ms,
        "nonce" => r.nonce,
        "key_id" => r.key_id
      })

  @doc "The chapters this signed request may read, as of now; spends its nonce."
  @spec authorize(request(), binary()) :: {:ok, [String.t()]} | {:error, atom()}
  def authorize(request, signature) do
    now = System.system_time(:millisecond)

    with {:ok, chapters} <- chapters(Log.gate().role_keys, request, signature, now),
         :ok <- Nonces.claim(request.nonce, request.timestamp_ms),
         do: {:ok, chapters}
  end

  @doc false
  def chapters(role_keys, request, signature, now_ms) do
    bytes = signing_bytes(request)

    chapters =
      for {{chapter, "governance"}, keys} <- role_keys,
          Crypto.verify(bytes, signature, keys[request.key_id] || ""),
          do: chapter

    cond do
      not (is_binary(request.nonce) and byte_size(request.nonce) in 16..128) ->
        {:error, :invalid_nonce}

      abs(now_ms - request.timestamp_ms) > Access.window_ms() ->
        {:error, :stale_request}

      chapters == [] ->
        {:error, :not_governance}

      true ->
        {:ok, Enum.sort(chapters)}
    end
  end
end
