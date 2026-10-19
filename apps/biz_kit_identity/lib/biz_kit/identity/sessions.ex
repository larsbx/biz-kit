defmodule BizKit.Identity.Sessions do
  @moduledoc """
  Local application sessions, issued after a provider sign-in. Short-lived
  (`:session_ttl_ms`, default one hour) and revocable one at a time or per
  principal. Held in memory, in one process for the whole cluster
  (`BizKit.Cluster.Singleton`), so a session works on every node and
  revoking it revokes it everywhere. If that process moves to another node,
  everyone is signed out, which fails closed, as a restart does.

  A session authenticates a principal only. Every protected operation still
  checks the principal's current ledger grants.
  """

  use GenServer

  @table __MODULE__
  @default_ttl_ms 3_600_000

  @type id :: String.t()
  @type t :: %{principal: String.t(), identity: BizKit.Identity.identity(), expires_at: integer()}

  @server BizKit.Cluster.Singleton.name(__MODULE__)

  def ttl_ms, do: Application.get_env(:biz_kit_identity, :session_ttl_ms, @default_ttl_ms)

  @spec create(String.t(), BizKit.Identity.identity()) :: id()
  def create(principal, identity) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    expires_at = System.system_time(:millisecond) + ttl_ms()
    :ok = GenServer.call(@server, {:create, {id, principal, identity, expires_at}})
    id
  end

  @spec fetch(id(), integer()) :: {:ok, t()} | {:error, :unknown_session | :expired}
  def fetch(id, now_ms), do: GenServer.call(@server, {:fetch, id, now_ms})

  @spec revoke(id()) :: :ok
  def revoke(id), do: GenServer.call(@server, {:revoke, {id, :_, :_, :_}})

  @spec revoke_principal(String.t()) :: :ok
  def revoke_principal(principal), do: GenServer.call(@server, {:revoke, {:_, principal, :_, :_}})

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

  def handle_call({:fetch, id, now_ms}, _from, state) do
    reply =
      case :ets.lookup(@table, id) do
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
  def handle_info(:sweep, state) do
    now = System.system_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, 60_000)
end
