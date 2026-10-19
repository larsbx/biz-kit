defmodule CoopSubstrate.ClusterTest do
  @moduledoc """
  The ledger and its stores as one service across nodes
  (docs/architecture/2026-10-19-cluster.md). A peer node that runs none of
  them itself appends, proves and approves an enrolment and spends nonces
  through the cluster's one appender and stores, and its feed processes
  hear every append.
  """
  use ExUnit.Case, async: false
  use CoopSubstrate.LogCase

  import CoopSubstrate.TaskTimingFixtures

  alias BizKit.Cluster.Peers
  alias CoopSubstrate.{Crypto, Enrolments, Feed, Log}

  @scope {"chapter-genesis", "tenant-1", "project-1"}

  setup_all do
    Peers.distribute!()
  end

  setup do
    {_, peer} = Peers.start!()
    Peers.mesh!([peer])
    gov = new_member("governance")
    {:ok, _} = Log.append(declare_governance(gov))
    %{peer: peer, gov: gov}
  end

  defp on(peer, module, fun, args), do: :erpc.call(peer, module, fun, args)
  defp grant(w), do: device_grant(w.gov, new_member("operator"), "bob", "Laptop")

  test "another node appends through the one appender", w do
    assert on(w.peer, Log, :head, []) == Log.head()

    assert {:ok, [appended]} =
             on(w.peer, Log, :append, [grant(w)])

    assert Log.head().global_seq == appended.global_seq
  end

  # As on the other side of a partition: two appenders, one store.
  test "a second appender cannot fork the ledger; the stale one starts again", w do
    {:ok, rogue} = Log.start_link(name: :rogue_appender)
    on_exit(fn -> Process.alive?(rogue) && GenServer.stop(rogue) end)
    Process.unlink(rogue)

    {:ok, [moved]} = Log.append(grant(w), rogue)
    stale = GenServer.whereis(Log.server())

    assert {:error, {:store_append_failed, :wrong_expected_version}} = Log.append(grant(w))

    # It stepped down and came back from the store, the rogue's event included.
    await(fn -> GenServer.whereis(Log.server()) not in [nil, stale] end)
    assert Log.head().global_seq == moved.global_seq
    assert {:ok, [_]} = Log.append(grant(w))
    assert :ok = Log.verify_chains()
  end

  test "an enrolment asked on one node is approved from another", w do
    device = new_member("operator")
    identity = %{issuer: "https://idp.test", subject: "sub-alice"}
    key_id = device.signer.key_id

    {:ok, c} =
      Enrolments.begin("alice", identity, @scope, key_id, device.signer.pubkey, "Laptop")

    # Proved, fetched and approved over there; held and appended here.
    {:ok, request} =
      on(w.peer, Enrolments, :prove, ["alice", c.id, Crypto.sign(c.statement, device.seed)])

    assert {:ok, %{principal_id: "alice"}} = on(w.peer, Enrolments, :fetch, [request.code])

    {:ok, pending} = Enrolments.prepare_approval(request.code, w.gov.signer.key_id)
    signature = Crypto.sign(pending.signing_bytes, w.gov.seed)

    assert {:ok, %{type: "TaskOperatorGrantedV1"}} =
             on(w.peer, Enrolments, :approve, [request.code, pending.id, signature])

    assert Enrolments.status("alice", @scope, key_id) == :enrolled
  end

  test "a nonce spent on one node is spent on all", w do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    now = System.system_time(:millisecond)

    assert on(w.peer, Feed.Nonces, :claim, [nonce, now]) == :ok
    assert Feed.Nonces.claim(nonce, now) == {:error, :replayed}
  end

  test "a feed process on another node hears every append", w do
    Peers.relay!(w.peer, Feed, :ledger, self())
    await_member(w.peer)

    {:ok, [appended]} = Log.append(grant(w))
    peer = w.peer
    assert_receive {:relayed, ^peer, {:coop_ledger, [^appended]}}, 2_000
  end

  defp await(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries > 0 -> Process.sleep(10) && await(fun, tries - 1)
      true -> flunk("never happened")
    end
  end

  # :pg learns of a remote member asynchronously.
  defp await_member(peer, tries \\ 100) do
    cond do
      Enum.any?(:pg.get_members(Feed, :ledger), &(node(&1) == peer)) -> :ok
      tries > 0 -> Process.sleep(10) && await_member(peer, tries - 1)
      true -> flunk("the peer's feed process never joined")
    end
  end
end
