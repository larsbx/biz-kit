defmodule BizKit.Identity.DurableSessionsTest do
  @moduledoc """
  A native app's session lasts until the person signs out
  (docs/architecture/2026-10-21-native-sign-in.md): no time limit, and kept in
  the configured `SessionStore` so a restart does not end it. Logout, revoking
  the principal and removing the identity binding still end it at once.
  """
  use ExUnit.Case, async: false

  alias BizKit.Identity
  alias BizKit.Identity.{Principal, Sessions}

  defmodule MemoryStore do
    @moduledoc "A `SessionStore` that outlives the session process, as a database does."
    @behaviour BizKit.Identity.SessionStore

    def start, do: Agent.start_link(fn -> %{} end, name: __MODULE__)
    def rows, do: Agent.get(__MODULE__, & &1)

    @impl true
    def put(hash, principal, identity, authenticated_at) do
      row = %{principal: principal, identity: identity, authenticated_at: authenticated_at}
      Agent.update(__MODULE__, &Map.put(&1, hash, row))
    end

    @impl true
    def get(hash), do: Agent.get(__MODULE__, &Map.fetch(&1, hash))

    @impl true
    def delete(hash), do: Agent.update(__MODULE__, &Map.delete(&1, hash))

    @impl true
    def delete_principal(principal),
      do:
        Agent.update(
          __MODULE__,
          &Map.reject(&1, fn {_hash, row} -> row.principal == principal end)
        )
  end

  @identity %{issuer: "https://idp.test", subject: "alice"}

  setup do
    env = Application.get_all_env(:biz_kit_identity)

    on_exit(fn ->
      for {key, _value} <- Application.get_all_env(:biz_kit_identity),
          not Keyword.has_key?(env, key),
          do: Application.delete_env(:biz_kit_identity, key)

      Application.put_all_env(biz_kit_identity: env)
    end)

    {:ok, _store} = MemoryStore.start()
    Application.put_env(:biz_kit_identity, :session_store, MemoryStore)
    principal = Principal.new_id()
    Application.put_env(:biz_kit_identity, :bindings, [Map.put(@identity, :principal, principal)])
    %{principal: principal}
  end

  # The session process dies and its supervisor starts it again, empty: what a
  # restart, or the singleton moving to another node, does to memory.
  defp restart_sessions do
    name = BizKit.Cluster.Singleton.name(Sessions)
    pid = GenServer.whereis(name)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
    wait_until(fn -> is_pid(GenServer.whereis(name)) and GenServer.whereis(name) != pid end)
  end

  defp wait_until(check, tries \\ 100) do
    cond do
      check.() -> :ok
      tries == 0 -> flunk("the session process did not come back")
      true -> Process.sleep(10) && wait_until(check, tries - 1)
    end
  end

  test "a native session has no time limit", ctx do
    session = Sessions.create_native(ctx.principal, @identity)
    a_year_on = System.system_time(:millisecond) + 365 * 86_400_000

    assert {:ok, %{principal: principal, expires_at: :never}} =
             Identity.session(session, a_year_on)

    assert principal == ctx.principal
  end

  test "it survives a restart, and only a hash of it is stored", ctx do
    session = Sessions.create_native(ctx.principal, @identity)
    {:ok, %{authenticated_at: signed_in}} = Identity.session(session)

    restart_sessions()

    # A session that lasts until sign-out says nothing of how recently it was
    # earned; when it was earned survives with it, for a step-up to ask.
    assert {:ok, %{principal: principal, authenticated_at: ^signed_in}} =
             Identity.session(session)

    assert principal == ctx.principal
    assert Map.keys(MemoryStore.rows()) == [:crypto.hash(:sha256, session)]
    refute Map.has_key?(MemoryStore.rows(), session)
  end

  test "signing out ends it everywhere, restart or not", ctx do
    session = Sessions.create_native(ctx.principal, @identity)

    :ok = Identity.logout(session)
    restart_sessions()

    assert {:error, :unknown_session} = Identity.session(session)
    assert MemoryStore.rows() == %{}
  end

  test "revoking the principal ends it, restart or not", ctx do
    session = Sessions.create_native(ctx.principal, @identity)

    other =
      Sessions.create_native(Principal.new_id(), %{issuer: "https://idp.test", subject: "bob"})

    :ok = Identity.revoke_principal(ctx.principal)
    restart_sessions()

    assert {:error, :unknown_session} = Identity.session(session)
    assert map_size(MemoryStore.rows()) == 1
    assert Sessions.fetch(other, System.system_time(:millisecond)) |> elem(0) == :ok
  end

  test "removing the binding ends it, and it is forgotten", ctx do
    session = Sessions.create_native(ctx.principal, @identity)
    Application.put_env(:biz_kit_identity, :bindings, [])

    assert {:error, :unbound} = Identity.session(session)
    assert MemoryStore.rows() == %{}
  end

  test "a web session keeps its time limit and is never stored", ctx do
    session = Sessions.create(ctx.principal, @identity)
    later = System.system_time(:millisecond) + Identity.session_ttl_ms() + 1

    assert {:error, :expired} = Identity.session(session, later)
    assert MemoryStore.rows() == %{}
  end

  test "an unknown token is unknown, and only a native one is looked for in the store", ctx do
    assert {:error, :unknown_session} = Identity.session("nat_made-up")

    # A browser's token never reaches the store, so one stored under its hash is not found.
    web = "made-up"
    MemoryStore.put(:crypto.hash(:sha256, web), ctx.principal, @identity, 0)
    assert {:error, :unknown_session} = Identity.session(web)
  end

  test "a session knows when it was signed in", ctx do
    before = System.system_time(:millisecond)
    native = Sessions.create_native(ctx.principal, @identity)
    web = Sessions.create(ctx.principal, @identity)
    later = System.system_time(:millisecond)

    for session <- [native, web] do
      assert {:ok, %{authenticated_at: at}} = Identity.session(session)
      assert at in before..later
    end
  end

  test "a native token says so; a browser's does not", ctx do
    assert "nat_" <> _rest = Sessions.create_native(ctx.principal, @identity)
    refute String.starts_with?(Sessions.create(ctx.principal, @identity), "nat_")
  end
end
