defmodule SpruceGoose.Web.NativeSessionStore do
  @moduledoc """
  `BizKit.Identity.SessionStore` in SpruceGoose's Postgres: native apps'
  sessions survive a restart and last until signed out
  (docs/architecture/2026-10-21-native-sign-in.md). Rows are keyed by the
  token's SHA-256; a row cannot be used as a session.
  """
  @behaviour BizKit.Identity.SessionStore

  import Ecto.Query, only: [from: 2]

  alias SpruceGoose.Repo

  @table "identity_native_sessions"

  @impl true
  def put(hash, principal, %{issuer: issuer, subject: subject}) do
    # AUTHORIZATION: identity's own session rows, written at a proven sign-in.
    {1, _} =
      Repo.insert_all(@table, [
        %{token_hash: hash, principal: principal, issuer: issuer, subject: subject}
      ])

    :ok
  end

  @impl true
  def get(hash) do
    from(s in @table,
      where: s.token_hash == ^hash,
      select: %{principal: s.principal, issuer: s.issuer, subject: s.subject}
    )
    # AUTHORIZATION: identity's own lookup, by the hash of a presented token.
    |> Repo.one()
    |> case do
      nil ->
        :error

      row ->
        {:ok, %{principal: row.principal, identity: %{issuer: row.issuer, subject: row.subject}}}
    end
  end

  @impl true
  def delete(hash) do
    # AUTHORIZATION: logout of the presented session, by its hash.
    Repo.delete_all(from(s in @table, where: s.token_hash == ^hash))
    :ok
  end

  @impl true
  def delete_principal(principal) do
    # AUTHORIZATION: identity's own revocation of a principal's sessions.
    Repo.delete_all(from(s in @table, where: s.principal == ^principal))
    :ok
  end
end
