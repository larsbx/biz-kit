defmodule BizKit.Identity.Sessions do
  @moduledoc """
  Local application sessions, issued after a provider sign-in. Short-lived
  (`:session_ttl_ms`, default one hour) and revocable one at a time or per
  principal. Held in memory, in one process for the whole cluster
  (`BizKit.Cluster.Singleton`), so a session works on every node and
  revoking it revokes it everywhere. If that process moves to another node,
  everyone is signed out, which fails closed, as a restart does.

  A native app's session (`create_native/2`) has no time limit: it lasts until
  the person signs out, or the principal's sessions are revoked, or the
  identity binding is removed. It is also kept in the configured
  `BizKit.Identity.SessionStore`, by hash, so a restart or a move does not end
  it; the first use afterwards reads it back.

  Each session records when the person signed in (`authenticated_at`), so an
  operation that needs a recent sign-in, a step-up, can ask for one: holding a
  session that lasts until sign-out says nothing about how recently it was
  earned.

  A session authenticates a principal only. Every protected operation still
  checks the principal's current ledger grants.
  """

  use GenServer

  alias BizKit.Identity.SessionStore

  @table __MODULE__
  @native "nat_"
  @default_ttl_ms 3_600_000

  @type id :: String.t()
  @typedoc """
  `expires_at` is `:never` for a native session. `authenticated_at` is when the
  person signed in. Both are Unix milliseconds.
  """
  @type t :: %{
          principal: String.t(),
          identity: BizKit.Identity.identity(),
          expires_at: integer() | :never,
          authenticated_at: integer()
        }

  @server BizKit.Cluster.Singleton.name(__MODULE__)

  def ttl_ms, do: Application.get_env(:biz_kit_identity, :session_ttl_ms, @default_ttl_ms)

  @doc "A browser's session, ending after `ttl_ms/0`."
  @spec create(String.t(), BizKit.Identity.identity()) :: id()
  def create(principal, identity) do
    id = new_id()
    now = System.system_time(:millisecond)
    :ok = GenServer.call(@server, {:create, {key(id), principal, identity, now + ttl_ms(), now}})
    id
  end

  @doc "A native app's session: no time limit, and stored first so a restart keeps it."
  @spec create_native(String.t(), BizKit.Identity.identity()) :: id()
  def create_native(principal, identity) do
    id = @native <> new_id()
    now = System.system_time(:millisecond)
    :ok = GenServer.call(@server, {:create_native, {key(id), principal, identity, :never, now}})
    id
  end

  @doc """
  A live session. One not in memory is looked for in the store, as after a
  restart, and kept in memory again if found. Store reads run in the
  caller's process; durable writes and revocations run in the singleton. The
  read ticket belongs to this singleton incarnation and is invalidated by
  every revocation before a recovered row can enter memory.
  """
  @spec fetch(id(), integer()) :: {:ok, t()} | {:error, :unknown_session | :expired}
  def fetch(id, now_ms), do: fetch_key(key(id), now_ms)

  defp fetch_key(id, now_ms) do
    with {:restore_ticket, ticket} <- GenServer.call(@server, {:fetch, id, now_ms}),
         {:ok, %{principal: principal, identity: identity, authenticated_at: at}} <-
           SessionStore.impl().get(digest(id)) do
      GenServer.call(@server, {:restore, ticket, {id, principal, identity, :never, at}})
    else
      :error -> {:error, :unknown_session}
      found_or_refused -> found_or_refused
    end
  end

  @spec revoke(id()) :: :ok
  def revoke(id) do
    GenServer.call(@server, {:revoke_token, key(id)})
  end

  @spec revoke_principal(String.t()) :: :ok
  def revoke_principal(principal) do
    GenServer.call(@server, {:revoke_principal, principal})
  end

  defp new_id, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  # Native tokens say so, so a browser's cookie, forged or expired, never
  # reaches the store.
  defp native?({native, _hash}), do: native
  defp native?(id), do: is_binary(id) and String.starts_with?(id, @native)
  defp key(id), do: {native?(id), :crypto.hash(:sha256, id)}
  defp digest({_native, hash}), do: hash

  @doc "Non-bearer lookup reference. Never accepted by fetch/2 as a token."
  def reference(id) when is_binary(id) do
    prefix = if native?(id), do: "nsr_", else: "wsr_"
    prefix <> Base.url_encode64(:crypto.hash(:sha256, id), padding: false)
  end

  @doc "Look up a reference from a trusted, authenticated application session."
  def fetch_reference(reference, now_ms) do
    with <<prefix::binary-size(4), encoded::binary>> <- reference,
         true <- prefix in ["nsr_", "wsr_"],
         {:ok, hash} when byte_size(hash) == 32 <- Base.url_decode64(encoded, padding: false) do
      fetch_key({prefix == "nsr_", hash}, now_ms)
    else
      _ -> {:error, :unknown_session}
    end
  end

  def revoke_reference(reference) do
    with <<prefix::binary-size(4), encoded::binary>> <- reference,
         true <- prefix in ["nsr_", "wsr_"],
         {:ok, hash} when byte_size(hash) == 32 <- Base.url_decode64(encoded, padding: false) do
      GenServer.call(@server, {:revoke_token, {prefix == "nsr_", hash}})
    else
      _ -> :ok
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :protected, :named_table])
    schedule()
    {:ok, make_ref()}
  end

  @impl true
  def handle_call({:create, row}, _from, state) do
    true = :ets.insert_new(@table, row)
    {:reply, :ok, state}
  end

  # Durable writes and deletions share the same serialization point as ETS.
  def handle_call({:create_native, {id, principal, identity, :never, at} = row}, _from, state) do
    :ok = SessionStore.impl().put(digest(id), principal, identity, at)
    true = :ets.insert_new(@table, row)
    {:reply, :ok, state}
  end

  # Even an unrelated revocation invalidates pending reads conservatively.
  # Such a request fails closed; a fresh fetch can recover an unrevoked row.
  def handle_call({:restore, ticket, row}, _from, state) do
    if ticket == state do
      :ets.insert(@table, row)
      {id, _, _, _, _} = row
      handle_call({:fetch, id, 0}, nil, state)
    else
      {:reply, {:error, :unknown_session}, state}
    end
  end

  def handle_call({:fetch, id, now_ms}, _from, state) do
    reply =
      case :ets.lookup(@table, id) do
        # A native session's `:never` passes: every number sorts before an atom.
        [{^id, principal, identity, expires_at, at}] when now_ms < expires_at ->
          {:ok,
           %{
             principal: principal,
             identity: identity,
             expires_at: expires_at,
             authenticated_at: at
           }}

        [_expired] ->
          :ets.delete(@table, id)
          {:error, :expired}

        [] ->
          if native?(id), do: {:restore_ticket, state}, else: {:error, :unknown_session}
      end

    {:reply, reply, state}
  end

  def handle_call({:revoke_token, id}, _from, _state) do
    if native?(id), do: :ok = SessionStore.impl().delete(digest(id))
    :ets.delete(@table, id)
    {:reply, :ok, make_ref()}
  end

  def handle_call({:revoke_principal, principal}, _from, _state) do
    :ok = SessionStore.impl().delete_principal(principal)
    :ets.match_delete(@table, {:_, principal, :_, :_, :_})
    {:reply, :ok, make_ref()}
  end

  @impl true
  # `:never` is never below `now`, so native sessions are not swept.
  def handle_info(:sweep, state) do
    now = System.system_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :_, :"$1", :_}, [{:<, :"$1", now}], [true]}])
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, 60_000)
end
