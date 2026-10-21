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

  A session authenticates a principal only. Every protected operation still
  checks the principal's current ledger grants.
  """

  use GenServer

  alias BizKit.Identity.SessionStore

  @table __MODULE__
  @native "nat_"
  @default_ttl_ms 3_600_000

  @type id :: String.t()
  @typedoc "`expires_at` is `:never` for a native session."
  @type t :: %{
          principal: String.t(),
          identity: BizKit.Identity.identity(),
          expires_at: integer() | :never
        }

  @server BizKit.Cluster.Singleton.name(__MODULE__)

  def ttl_ms, do: Application.get_env(:biz_kit_identity, :session_ttl_ms, @default_ttl_ms)

  @doc "A browser's session, ending after `ttl_ms/0`."
  @spec create(String.t(), BizKit.Identity.identity()) :: id()
  def create(principal, identity) do
    id = new_id()

    :ok =
      GenServer.call(
        @server,
        {:create, {id, principal, identity, System.system_time(:millisecond) + ttl_ms()}}
      )

    id
  end

  @doc "A native app's session: no time limit, and stored first so a restart keeps it."
  @spec create_native(String.t(), BizKit.Identity.identity()) :: id()
  def create_native(principal, identity) do
    id = @native <> new_id()
    :ok = SessionStore.impl().put(hash(id), principal, identity)
    :ok = GenServer.call(@server, {:create, {id, principal, identity, :never}})
    id
  end

  @doc """
  A live session. One not in memory is looked for in the store, as after a
  restart, and kept in memory again if found. The store is called from the
  caller's process, never from the session process.
  """
  @spec fetch(id(), integer()) :: {:ok, t()} | {:error, :unknown_session | :expired}
  def fetch(id, now_ms) do
    with {:error, :unknown_session} <- GenServer.call(@server, {:fetch, id, now_ms}),
         true <- native?(id) || {:error, :unknown_session},
         {:ok, %{principal: principal, identity: identity}} <- SessionStore.impl().get(hash(id)) do
      :ok = GenServer.call(@server, {:restore, {id, principal, identity, :never}})
      {:ok, %{principal: principal, identity: identity, expires_at: :never}}
    else
      :error -> {:error, :unknown_session}
      found_or_refused -> found_or_refused
    end
  end

  @spec revoke(id()) :: :ok
  def revoke(id) do
    :ok = GenServer.call(@server, {:revoke, {id, :_, :_, :_}})
    if native?(id), do: SessionStore.impl().delete(hash(id)), else: :ok
  end

  @spec revoke_principal(String.t()) :: :ok
  def revoke_principal(principal) do
    :ok = GenServer.call(@server, {:revoke, {:_, principal, :_, :_}})
    SessionStore.impl().delete_principal(principal)
  end

  defp new_id, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  # Native tokens say so, so a browser's cookie, forged or expired, never
  # reaches the store.
  defp native?(id), do: is_binary(id) and String.starts_with?(id, @native)
  defp hash(id), do: :crypto.hash(:sha256, id)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :protected, :named_table])
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_call({:create, row}, _from, state) do
    true = :ets.insert_new(@table, row)
    {:reply, :ok, state}
  end

  # Read back from the store; another caller may have restored it first.
  def handle_call({:restore, row}, _from, state) do
    :ets.insert(@table, row)
    {:reply, :ok, state}
  end

  def handle_call({:fetch, id, now_ms}, _from, state) do
    reply =
      case :ets.lookup(@table, id) do
        # A native session's `:never` passes: every number sorts before an atom.
        [{^id, principal, identity, expires_at}] when now_ms <= expires_at ->
          {:ok, %{principal: principal, identity: identity, expires_at: expires_at}}

        [_expired] ->
          :ets.delete(@table, id)
          {:error, :expired}

        [] ->
          {:error, :unknown_session}
      end

    {:reply, reply, state}
  end

  def handle_call({:revoke, pattern}, _from, state) do
    :ets.match_delete(@table, pattern)
    {:reply, :ok, state}
  end

  @impl true
  # `:never` is never below `now`, so native sessions are not swept.
  def handle_info(:sweep, state) do
    now = System.system_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, 60_000)
end
