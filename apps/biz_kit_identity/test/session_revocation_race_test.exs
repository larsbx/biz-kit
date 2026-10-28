defmodule BizKit.Identity.SessionRevocationRaceTest do
  use ExUnit.Case, async: false

  alias BizKit.Cluster.{Peers, Singleton}
  alias BizKit.Identity.{PausedSessionStore, Sessions}

  @identity %{issuer: "https://idp.test", subject: "alice"}

  setup do
    Peers.distribute!()
    old = Application.get_env(:biz_kit_identity, :session_store)
    {:ok, store} = PausedSessionStore.start_link()
    Application.put_env(:biz_kit_identity, :session_store, PausedSessionStore)

    on_exit(fn ->
      if old,
        do: Application.put_env(:biz_kit_identity, :session_store, old),
        else: Application.delete_env(:biz_kit_identity, :session_store)

      if Process.alive?(store), do: Agent.stop(store)
    end)

    {_, peer} = Peers.start!()
    Peers.mesh!([peer])

    :ok =
      :erpc.call(peer, Application, :put_env, [
        :biz_kit_identity,
        :session_store,
        PausedSessionStore
      ])

    %{peer: peer}
  end

  for kind <- [:token, :principal] do
    @kind kind
    test "a paused read cannot undo #{@kind} revocation, including restart and node move", ctx do
      token = Sessions.create_native("alice", @identity)
      survivor = Sessions.create_native("bob", %{issuer: "https://idp.test", subject: "bob"})
      now = System.system_time(:millisecond)
      assert {:ok, %{authenticated_at: at}} = Sessions.fetch(survivor, now)
      restart_sessions()
      PausedSessionStore.pause_next_read(self())
      fetch = Task.async(fn -> Sessions.fetch(token, now) end)
      assert_receive {:store_read, reader, ref}

      case @kind do
        :token -> :ok = :erpc.call(ctx.peer, Sessions, :revoke, [token])
        :principal -> :ok = :erpc.call(ctx.peer, Sessions, :revoke_principal, ["alice"])
      end

      send(reader, {:resume, ref})
      assert Task.await(fetch) == {:error, :unknown_session}
      assert_invalid(token, ctx.peer, now)
      restart_sessions()
      assert_invalid(token, ctx.peer, now)

      # Remove the local keeper, so the singleton really moves to the peer.
      :ok = Supervisor.terminate_child(BizKit.Identity.Supervisor, Sessions)

      try do
        :ok = :erpc.call(ctx.peer, PausedSessionStore, :start_remote_keeper, [])
        assert node(GenServer.whereis(Singleton.name(Sessions))) == ctx.peer
        assert_invalid(token, ctx.peer, now)
        assert {:ok, %{principal: "bob", authenticated_at: ^at}} = Sessions.fetch(survivor, now)
      after
        :ok = :erpc.call(ctx.peer, Supervisor, :stop, [BizKit.Identity.RaceSupervisor])
        {:ok, _} = Supervisor.restart_child(BizKit.Identity.Supervisor, Sessions)
      end
    end
  end

  test "a read from a dead singleton incarnation cannot restore a deleted row", ctx do
    token = Sessions.create_native("alice", @identity)
    now = System.system_time(:millisecond)
    restart_sessions()
    PausedSessionStore.pause_next_read(self())
    fetch = Task.async(fn -> Sessions.fetch(token, now) end)
    assert_receive {:store_read, reader, ref}
    :ok = Sessions.revoke(token)
    restart_sessions()
    send(reader, {:resume, ref})
    assert Task.await(fetch) == {:error, :unknown_session}
    assert_invalid(token, ctx.peer, now)
  end

  test "a restart invalidates a pending ticket without deleting an unrevoked session" do
    token = Sessions.create_native("alice", @identity)
    now = System.system_time(:millisecond)
    restart_sessions()
    PausedSessionStore.pause_next_read(self())
    fetch = Task.async(fn -> Sessions.fetch(token, now) end)
    assert_receive {:store_read, reader, ref}
    restart_sessions()
    send(reader, {:resume, ref})
    assert Task.await(fetch) == {:error, :unknown_session}
    assert {:ok, %{principal: "alice"}} = Sessions.fetch(token, now)
  end

  defp assert_invalid(token, peer, now) do
    assert Sessions.fetch(token, now) == {:error, :unknown_session}
    assert :erpc.call(peer, Sessions, :fetch, [token, now]) == {:error, :unknown_session}
  end

  defp restart_sessions do
    :ok = Supervisor.terminate_child(BizKit.Identity.Supervisor, Sessions)
    {:ok, _} = Supervisor.restart_child(BizKit.Identity.Supervisor, Sessions)
  end
end
