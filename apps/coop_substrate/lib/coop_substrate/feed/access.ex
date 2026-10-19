defmodule CoopSubstrate.Feed.Access do
  @moduledoc """
  Who may read a project's change feed
  (docs/architecture/2026-10-18-change-feed.md#access). Pure.

  A reader proves possession of the key of an active **operator, suggester or
  reviewer** grant for exactly the requested scope, by signing a fresh
  request. The grants are the ledger's own (`TaskOperatorGrantedV1`,
  `TaskSuggesterGrantedV1`, `TaskReviewerGrantedV1`); a delegation confers no
  read access. The signature binds the method, path,
  scope, cursor, time and nonce, so it cannot be replayed against another
  resource or position. Nonces are spent by `CoopSubstrate.Feed.Nonces`.

  The resulting reader stays authorised while `live?/2` holds: a feed session
  ends when its grant is revoked.
  """

  alias CoopSubstrate.Canonical
  alias CoopSubstrate.Crypto
  alias CoopSubstrate.Feed.View

  @enforce_keys [:grant_id, :role, :principal_id, :scope]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          grant_id: String.t(),
          role: :operator | :suggester | :reviewer,
          principal_id: String.t(),
          scope: View.scope()
        }

  @type request :: %{
          method: String.t(),
          path: String.t(),
          scope: View.scope(),
          cursor: non_neg_integer() | nil,
          timestamp_ms: integer(),
          nonce: String.t(),
          authorization_event_id: String.t(),
          key_id: String.t()
        }

  @window_ms 60_000

  @doc "How far a request's timestamp may be from the server's clock, either way."
  def window_ms, do: @window_ms

  @doc "The bytes a reader signs: the request, canonically encoded."
  @spec signing_bytes(request()) :: binary()
  def signing_bytes(%{scope: {chapter, tenant, project}} = r) do
    Canonical.encode!(%{
      "schema" => "CoopFeedReadV1",
      "method" => r.method,
      "path" => r.path,
      "chapter_id" => chapter,
      "tenant_id" => tenant,
      "project_id" => project,
      "cursor" => r.cursor,
      "timestamp_ms" => r.timestamp_ms,
      "nonce" => r.nonce,
      "authorization_event_id" => r.authorization_event_id,
      "key_id" => r.key_id
    })
  end

  @spec authorize(map(), request(), binary(), integer()) :: {:ok, t()} | {:error, atom()}
  def authorize(orchestration, request, signature, now_ms) do
    with :ok <-
           check(is_binary(request.nonce) and byte_size(request.nonce) in 16..128, :invalid_nonce),
         :ok <- check(abs(now_ms - request.timestamp_ms) <= @window_ms, :stale_request),
         {:ok, role, grant} <- grant(orchestration, request.authorization_event_id),
         :ok <- check(grant.active, :grant_revoked),
         :ok <- check(scope(grant) == request.scope, :scope_mismatch),
         :ok <- check(grant.key_id == request.key_id, :key_mismatch),
         :ok <-
           check(Crypto.verify(signing_bytes(request), signature, grant.pubkey), :bad_signature) do
      {:ok,
       %__MODULE__{
         grant_id: request.authorization_event_id,
         role: role,
         principal_id: grant.principal_id,
         scope: request.scope
       }}
    end
  end

  @doc """
  The reader for a principal authenticated outside the ledger (a person
  signed in through biz-kit's identity layer): its active operator grant on
  the scope, else its suggester grant, else its reviewer grant. Delegations
  confer nothing.
  """
  @spec for_principal(map(), String.t(), View.scope()) :: {:ok, t()} | {:error, :no_grant}
  def for_principal(o, principal_id, scope) do
    [{:operator, o.grants}, {:suggester, o.suggester_grants}, {:reviewer, o.dod_grants}]
    |> Enum.flat_map(fn {role, grants} ->
      for {id, g} <- grants,
          g.active,
          g.principal_id == principal_id,
          scope(g) == scope,
          do: %__MODULE__{grant_id: id, role: role, principal_id: principal_id, scope: scope}
    end)
    |> case do
      [reader | _] -> {:ok, reader}
      [] -> {:error, :no_grant}
    end
  end

  @doc "Whether the reader's grant is still active."
  @spec live?(map(), t()) :: boolean()
  def live?(orchestration, %__MODULE__{grant_id: id}),
    do: match?({:ok, _, %{active: true}}, grant(orchestration, id))

  defp grant(o, id) do
    cond do
      Map.has_key?(o.grants, id) -> {:ok, :operator, o.grants[id]}
      Map.has_key?(o.suggester_grants, id) -> {:ok, :suggester, o.suggester_grants[id]}
      Map.has_key?(o.dod_grants, id) -> {:ok, :reviewer, o.dod_grants[id]}
      true -> {:error, :unknown_grant}
    end
  end

  defp scope(grant), do: {grant.chapter_id, grant.tenant_id, grant.project_id}

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}
end
